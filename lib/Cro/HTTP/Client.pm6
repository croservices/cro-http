use Base64;
use OO::Monitors;
use Cro::HTTP::Client::CookieJar;
use Cro::HTTP::Internal;
use Cro::HTTP::Header;
use Cro::HTTP::Request;
use Cro::HTTP::RequestSerializer;
use Cro::HTTP::ResponseParser;
use Cro::TCP;
use Cro::SSL;
use Cro::Uri;
use Cro;

my class ResponseParserExtension is ParserExtension {
    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::HTTP::Response }
}

my class RequestSerializerExtension is SerializerExtension {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Request }
}

class X::Cro::HTTP::Error is Exception {
    has $.response;

    method message() {
        "{$.response.get-response-phrase}"
    }
}

class X::Cro::HTTP::Error::Client is X::Cro::HTTP::Error {}
class X::Cro::HTTP::Error::Server is X::Cro::HTTP::Error {}

class X::Cro::HTTP::Client::BodyAlreadySet is Exception {
    method message() {
        "Body was set twice"
    }
}

class X::Cro::HTTP::Client::IncorrectHeaderType is Exception {
    has $.what;

    method message() {
        "Incorrect header of type {$.what.^name} was passed to HTTP client"
    }
}

class X::Cro::HTTP::Client::TooManyRedirects is Exception {
    method message() {
        "Too many redirects"
    }
}

class X::Cro::HTTP::Client::InvalidAuth is Exception {
    has $.reason;

    method message() {
        "Authentication failed: {$!reason}"
    }
}

class Cro::HTTP::Client {
    my class Pipeline {
        has Bool $.secure;
        has Str $.host;
        has Int $.port;
        has Supplier $!in;
        has Supply $!out;
        has Tap $!tap;
        has $!next-response-vow;
        has Bool $.dead = False;

        submethod BUILD(:$!secure!, :$!host!, :$!port!, :$!in!, :$out!) {
            $!tap = supply {
                whenever $out {
                    my $vow = $!next-response-vow;
                    $!next-response-vow = Nil;
                    $vow.keep($_);
                    LAST $!dead = True;
                    QUIT {
                        default {
                            $!dead = True;
                            if $!next-response-vow {
                                $!next-response-vow.break($_);
                                $!next-response-vow = Nil;
                            }
                        }
                    }
                }
            }.tap
        }

        method send-request($request --> Promise) {
            my $next-response-promise = Promise.new;
            $!next-response-vow = $next-response-promise.vow;
            $!in.emit($request);
            return $next-response-promise;
        }
    }

    my monitor ConnectionCache {
        has %!cached;

        method pipeline-for($secure, $host, $port) {
            if %!cached{self!key($secure, $host, $port)} -> @available {
                while @available {
                    my $pipeline = @available.shift;
                    return $pipeline unless $pipeline.dead;
                }
            }
            Nil
        }

        method add-pipeline($pipeline --> Nil) {
            with $pipeline {
                unless .dead {
                    push %!cached{self!key(.secure, .host, .port)}, $pipeline;
                }
            }
        }

        method !key($secure, $host, $port) {
            "{$secure ?? 'https' !! 'http'}\0$host\0$port\0"
        }
    }

    has @.headers;
    has $.cookie-jar;
    has $.body-serializers;
    has $.add-body-serializers;
    has $.body-parsers;
    has $.add-body-parsers;
    has $.content-type;
    has $.follow;
    has %.auth;
    has $.persistent = True;
    has $!connection-cache = ConnectionCache.new;

    method persistent() {
        self ?? $!persistent !! False
    }

    submethod BUILD(:$cookie-jar, :@!headers, :$!content-type,
                    :$!body-serializers, :$!add-body-serializers,
                    :$!body-parsers, :$!add-body-parsers,
                    :$!follow, :%!auth) {
        when $cookie-jar ~~ Bool {
            $!cookie-jar = Cro::HTTP::Client::CookieJar.new;
        }
        when $cookie-jar ~~ Cro::HTTP::Client::CookieJar {
            $!cookie-jar = $cookie-jar;
        }
        if (%!auth<username>:exists) && (%!auth<password>:exists) {
            my $reason = 'Both basic and bearer authentication methods cannot be used';
            die X::Cro::HTTP::Client::InvalidAuth.new(:$reason) if %!auth<bearer>:exists;
        }
    }

    multi method get($url, %options --> Promise) {
        self.request('GET', $url, %options)
    }
    multi method get($url, *%options --> Promise) {
        self.request('GET', $url, %options)
    }

    multi method head($url, %options --> Promise) {
        self.request('HEAD', $url, %options)
    }
    multi method head($url, *%options --> Promise) {
        self.request('HEAD', $url, %options)
    }

    multi method post($url, %options --> Promise) {
        self.request('POST', $url, %options)
    }
    multi method post($url, *%options --> Promise) {
        self.request('POST', $url, %options)
    }

    multi method put($url, %options --> Promise) {
        self.request('PUT', $url, %options)
    }
    multi method put($url, *%options --> Promise) {
        self.request('PUT', $url, %options)
    }

    multi method delete($url, %options --> Promise) {
        self.request('DELETE', $url, %options)
    }
    multi method delete($url, *%options --> Promise) {
        self.request('DELETE', $url, %options)
    }

    multi method request(Str $method, $url, *%options --> Promise) {
        self.request($method, $url, %options)
    }
    multi method request(Str $method, $url, %options --> Promise) {
        my $parsed-url = $url ~~ Cro::Uri ?? $url !! Cro::Uri.parse(~$url);
        my $pipeline = self!get-pipeline($parsed-url);
        my $request-object = self!assemble-request($method, $parsed-url, %options);
        my $response-promise = $pipeline.send-request($request-object);

        my constant $redirect-codes = set(301, 302, 303, 307, 308);
        sub construct-url($path) {
            my $pos = $parsed-url.Str.index('/', 8);
            $parsed-url.Str.comb[0..$pos-1].join ~ $path;
        }

        Promise(supply {
            whenever $response-promise {
                # Consider adding the connection back into the cache to use it
                # again.
                if self && $!persistent {
                    unless .http-version eq '1.0' || (.header('connection') // '').lc eq 'close' {
                        $!connection-cache.add-pipeline($pipeline);
                    }
                }

                if 200 <= .status < 400 || .status == 101 {
                    my $follow;
                    if self {
                        $follow = %options<follow> // $!follow // 5;
                    } else {
                        $follow = %options<follow> // 5;
                    }
                    if .status ⊂ $redirect-codes && ($follow !=== False) {
                        my $remain = $follow === True ?? 4 !! $follow.Int - 1;
                        die X::Cro::HTTP::Client::TooManyRedirects.new if $remain < 0;
                        my $new-method = .status == 302|303 ?? 'GET' !! $method;
                        my %new-opts = %options;
                        %new-opts<follow> = $remain;
                        if .status == 302|303 {
                            %new-opts<body>:delete;
                            %new-opts<content-type>:delete;
                            %new-opts<content-length>:delete;
                        }
                        my $new-url;
                        $new-url = .header('location').starts-with('/')
                                   ?? construct-url($_.header('location'))
                                   !! .header('location');
                        my $req = self.request($new-method, $new-url, %new-opts);
                        whenever $req { .emit };
                    } else {
                        if self && $.cookie-jar.defined {
                            $.cookie-jar.add-from-response($_, $parsed-url);
                        }
                        .emit
                    }
                } elsif 400 <= .status < 500 {
                    my $auth;
                    if self {
                        $auth = %options<auth> // %!auth;
                    } else {
                        $auth = %options<auth> // {};
                    }
                    if .status == 401 && (%options<auth><if-asked>:exists) {
                        my %opts = %options;
                        %opts<auth><if-asked>:delete;
                        whenever self.request($method, $parsed-url, %options) { .emit };
                    } else {
                        die X::Cro::HTTP::Error::Client.new(response => $_);
                    }
                } elsif .status >= 500 {
                    die X::Cro::HTTP::Error::Server.new(response => $_);
                }
            }
        })
    }

    method !get-pipeline(Cro::Uri $url) {
        my $secure = $url.scheme.lc eq 'https';
        my $host = $url.host;
        my $port = $url.port // ($secure ?? 443 !! 80);
        if self && $!connection-cache.pipeline-for($secure, $host, $port) -> $pipeline {
            return $pipeline;
        }
        self!build-pipeline($secure, $host, $port)
    }

    method !build-pipeline($secure, $host, $port) {
        my @parts =
            (RequestSerializerExtension.new(add-body-serializers => $.add-body-serializers,
                                            body-serializers => $.body-serializers) if self),
            Cro::HTTP::RequestSerializer.new,
            $secure ?? Cro::SSL::Connector !! Cro::TCP::Connector,
            Cro::HTTP::ResponseParser.new,
            (ResponseParserExtension.new(add-body-parsers => $.add-body-parsers,
                                         body-parsers => $.body-parsers) if self);

        my $connector = Cro.compose(|@parts);
        my $in = Supplier::Preserving.new;
        my $out = $connector.establish($in.Supply, :$host, :$port);
        return Pipeline.new(:$secure, :$host, :$port, :$in, :$out)
    }

    method !assemble-request(Str $method, Cro::Uri $url, %options --> Cro::HTTP::Request) {
        my $target = $url.path || '/';
        my $request = Cro::HTTP::Request.new(:$method, :$target);
        $request.append-header('Host', $url.host);
        if self {
            $request.append-header('content-type', $.content-type) if $.content-type;
            self!set-headers($request, @.headers.List);
            $.cookie-jar.add-to-request($request, $url) if $.cookie-jar;
            if %!auth && !(%options<auth>:exists) {
                self!form-authentication($request, %!auth, %options<if-asked>:exists);
            }
        }
        my Bool $body-set = False;
        for %options.kv -> $_, $value {
            when 'body' {
                if !$body-set {
                    $request.set-body($value);
                    $body-set = True;
                } else {
                    die X::Cro::HTTP::Client::BodyAlreadySet.new;
                }
            }
            when 'body-byte-stream' {
                if !$body-set {
                    $request.set-body-byte-stream($value);
                    $body-set = True;
                } else {
                    die X::Cro::HTTP::Client::BodyAlreadySet.new;
                }
            }
            when 'content-type' {
                $request.append-header('content-type', $value)
            }
            when 'headers' {
                self!set-headers($request, $value.List) if $value ~~ Iterable;
            }
            when 'auth' {
                self!form-authentication: $request, %$value, %$value<if-asked>:exists;
            }
        }
        unless self.persistent || $request.has-header('connection') {
            $request.append-header('Connection', 'close');
        }
        return $request;
    }

    method !form-authentication($request, %data, Bool $skip) {
        return if $skip;
        if %data<username>:exists {
            my $hash = encode-base64("{%data<username>}:{%data<password>}", :str);
            $request.append-header('Authorization', "Basic $hash");
        } else {
            $request.append-header('Authorization', "Bearer {%data<bearer>}");
        }
    }

    method !set-headers($request, @headers) {
        for @headers {
            if not ($_ ~~ Cro::HTTP::Header || $_ ~~ Pair) {
                die X::Cro::HTTP::Client::IncorrectHeaderType.new(what => $_);
            } else {
                $request.append-header($_)
            }
        }
    }
}
