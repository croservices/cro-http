use Base64;
use OO::Monitors;
use Cro::HTTP::Client::CookieJar;
use Cro::HTTP::Internal;
use Cro::HTTP::Header;
use Cro::HTTP::Request;
use Cro::HTTP::RequestSerializer;
use Cro::HTTP::ResponseParser;
use Cro::HTTP2::FrameParser;
use Cro::HTTP2::FrameSerializer;
use Cro::HTTP2::RequestSerializer;
use Cro::HTTP2::ResponseParser;
use Cro::TCP;
use Cro::TLS;
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

class X::Cro::HTTP::Client::InvalidVersion is Exception {
    method message() {
        "Invalid HTTP version argument (may be :http<1.1>, :http<2>, or :http<1.1 2>)"
    }
}

class X::Cro::HTTP::Client::InvalidCookie is Exception {
    has $.bad;
    method message() {
        "Cannot add $!bad.^name() as a cookie (expected a hash of keys to values, " ~
        "or a list of Pair and Cro::HTTP::Cookie objects)"
    }
}

class Cro::HTTP::Client {
    my class Pipeline {
        has Bool $.secure;
        has Str $.host;
        has Int $.port;
        has Supplier $!in;
        has Tap $!tap;
        has $!next-response-vow;
        has Bool $.dead = False;

        submethod BUILD(:$!secure!, :$!host!, :$!port!, :$!in!, :$out!) {
            $!tap = supply {
                whenever $out {
                    my $vow = $!next-response-vow;
                    $!next-response-vow = Nil;
                    $vow.keep($_);
                    LAST {
                        $!dead = True;
                        if $!next-response-vow {
                            $!next-response-vow.break:
                                'Connection unexpectedly closed before response headers received';
                            $!next-response-vow = Nil;
                        }
                    }
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

        method close() { $!in.done }
    }

    my class Pipeline2 {
        has Lock $!lock = Lock.new;
        has Bool $.secure;
        has Str $.host;
        has Int $.port;
        has Supplier $!in;
        has Tap $!tap;
        has Bool $.dead = False;
        has $!next-stream-id = 1;
        has %!outstanding-stream-responses{Int};

        submethod BUILD(:$!secure!, :$!host!, :$!port!, :$!in!, :$out!) {
            $!tap = supply {
                whenever $out -> $response {
                    self.response($response);
                    LAST {
                        $!dead = True;
                        self.break-all-responses(X::AdHoc.new(message => 'Connection to server lost'));
                    }
                    QUIT {
                        default {
                            $!dead = True;
                            self.break-all-responses($_);
                        }
                    }
                }
            }.tap
        }

        method send-request($request --> Promise) {
            my $p = Promise.new;
            $!lock.protect: {
                my $stream-id = $!next-stream-id;
                $!next-stream-id += 2;
                $request.http2-stream-id = $stream-id;
                %!outstanding-stream-responses{$stream-id} = $p.vow;
            }
            $!in.emit($request);
            $p
        }

        method response($response) {
            my $vow = $!lock.protect: {
                %!outstanding-stream-responses{$response.http2-stream-id}:delete
            }
            $vow.keep($response);
        }

        method break-all-responses($error) {
            $!lock.protect: {
                for %!outstanding-stream-responses.values -> $vow {
                    $vow.break($error);
                }
                %!outstanding-stream-responses = ();
            }
        }

        method close() { $!in.done }
    }

    my monitor ConnectionCache {
        has %!cached-http1;
        has %!cached-http2;

        method pipeline-for($secure, $host, $port, $http) {
            my $key = self!key($secure, $host, $port);
            if $http eq '2' || !$http && $secure {
                if %!cached-http2{$key} -> $pipeline {
                    if $pipeline.dead {
                        %!cached-http2{$key}:delete;
                        return Nil;
                    }
                    else {
                        return $pipeline;
                    }
                }
            }
            if $http ne '1.1' && %!cached-http1{$key} -> @available {
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
                    when Pipeline2 {
                        %!cached-http2{self!key(.secure, .host, .port)} = $pipeline;
                    }
                    default {
                        push %!cached-http1{self!key(.secure, .host, .port)}, $pipeline;
                    }
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
    has $.persistent;
    has $!connection-cache = ConnectionCache.new;
    has $.http;
    has $.ca;
    has Cro::Uri $.base-uri;
    has $.push-promises = False;

    method persistent() {
        self ?? $!persistent !! False
    }

    submethod BUILD(:$cookie-jar, :@!headers, :$!content-type, :$base-uri,
                    :$!body-serializers, :$!add-body-serializers,
                    :$!body-parsers, :$!add-body-parsers,
                    :$!follow, :%!auth, :$!http, :$!persistent = True, :$!ca,
                    :$!push-promises) {
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
        with $!http {
            unless $_ eq '1.1' || $_ eq '2' || $_ eqv <1.1 2> {
                die X::Cro::HTTP::Client::InvalidVersion.new;
            }
        }
        with $base-uri {
            when Cro::Uri {
                $!base-uri = $_;
            }
            default {
                $!base-uri = Cro::Uri.parse(~$_);
            }
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

    multi method patch($url, %options --> Promise) {
        self.request('PATCH', $url, %options)
    }
    multi method patch($url, *%options --> Promise) {
        self.request('PATCH', $url, %options)
    }

    multi method request(Str $method, $url, *%options --> Promise) {
        self.request($method, $url, %options)
    }
    multi method request(Str $method, $url, %options --> Promise) {
        my $parsed-url = self && $!base-uri
            ?? $!base-uri.add($url)
            !! Cro::Uri.parse($url);
        my $http = self ?? $!http // %options<http> !! %options<http>;
        with $http {
            unless $_ eq '1.1' || $_ eq '2' || $_ eqv <1.1 2> {
                die X::Cro::HTTP::Client::InvalidVersion.new;
            }
        }
        else {
            $http = '';
        }
        my $request-object = self!assemble-request($method, $parsed-url, %options);

        my constant $redirect-codes = set(301, 302, 303, 307, 308);
        sub construct-url($path) {
            my $pos = $parsed-url.Str.index('/', 8);
            $parsed-url.Str.comb[0..$pos-1].join ~ $path;
        }

        my $enable-push = self ?? $!push-promises // %options<push-promises> !! %options<push-promises>;

        Promise(supply {
            whenever self!get-pipeline($parsed-url, $http, ca => %options<ca>, :$enable-push) -> $pipeline {
                if $pipeline !~~ Pipeline2 {
                    unless self.persistent || $request-object.has-header('connection') {
                        $request-object.append-header('Connection', 'close');
                    }
                }
                whenever $pipeline.send-request($request-object) {
                    # Consider adding the connection back into the cache to use it
                    # again.
                    if self && $!persistent {
                        unless .http-version eq '1.0' || (.header('connection') // '').lc eq 'close' {
                            $!connection-cache.add-pipeline($pipeline);
                        }
                    }
                    else {
                        $pipeline.close;
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
            }
        })
    }

    method !get-pipeline(Cro::Uri $url, $http, :$ca, :$enable-push) {
        my $secure = $url.scheme.lc eq 'https';
        my $host = $url.host;
        my $port = $url.port // ($secure ?? 443 !! 80);
        if self && $!connection-cache.pipeline-for($secure, $host, $port, $http) -> $pipeline {
            my $p = Promise.new;
            $p.keep($pipeline);
            $p
        }
        else {
            self!build-pipeline($secure, $host, $port, $http, :$ca, :$enable-push)
        }
    }

    my class VersionDecisionNotifier does Cro::Transform {
        has $.promise;
        has $.result;

        method consumes() { Cro::HTTP::Request }
        method produces() { Cro::HTTP::Request }
        method transformer($pipeline) {
            $!promise.keep($!result);
            return $pipeline;
        }
    }

    method !build-pipeline($secure, $host, $port, $http, :$ca, :$enable-push) {
        my @parts;
        my $version-decision = Promise.new;
        my $supports-alpn = supports-alpn();
        if self {
            push @parts, RequestSerializerExtension.new:
                add-body-serializers => $.add-body-serializers,
                body-serializers => $.body-serializers;
        }
        if $http eq '2' {
            push @parts, Cro::HTTP2::RequestSerializer.new;
            push @parts, Cro::HTTP2::FrameSerializer.new(:client, :$enable-push);
            $version-decision.keep('2');
        }
        elsif $http eq '1.1' || !$secure || !$supports-alpn {
            push @parts, Cro::HTTP::RequestSerializer.new;
            $version-decision.keep('1.1');
        }
        else {
            push @parts, Cro::ConnectionConditional.new(
                { (.alpn-result // '') eq 'h2' } => [
                    VersionDecisionNotifier.new(:promise($version-decision), :result('2')),
                    Cro::HTTP2::RequestSerializer.new,
                    Cro::HTTP2::FrameSerializer.new(:client, :$enable-push)
                ],
                [
                    VersionDecisionNotifier.new(:promise($version-decision), :result('1.1')),
                    Cro::HTTP::RequestSerializer.new
                ]
            );
        }
        push @parts, $secure ?? Cro::TLS::Connector !! Cro::TCP::Connector;
        if $http eq '2' {
            push @parts, Cro::HTTP2::FrameParser.new(:client);
            push @parts, Cro::HTTP2::ResponseParser.new(:$enable-push);
        }
        elsif $http eq '1.1' || !$secure || !$supports-alpn {
            push @parts, Cro::HTTP::ResponseParser.new;
        }
        else {
            push @parts, Cro::ConnectionConditional.new(
                { (.alpn-result // '') eq 'h2' } => [
                    Cro::HTTP2::FrameParser.new(:client),
                    Cro::HTTP2::ResponseParser.new
                ],
                Cro::HTTP::ResponseParser.new
            );
        }
        if self {
            push @parts, ResponseParserExtension.new:
                add-body-parsers => $.add-body-parsers,
                body-parsers => $.body-parsers;
        }
        my $connector = Cro.compose(|@parts);

        my %tls-config = $supports-alpn && $secure && $http ne '1.1'
            ?? alpn => ($http eq 'h2' ?? 'h2' !! <h2 http/1.1>)
            !! ();
        my $in = Supplier::Preserving.new;
        my %ca = self ?? (self.ca // $ca // {}) !! $ca // {};
        my $out = $version-decision
            ?? $connector.establish($in.Supply, :$host, :$port, |{%tls-config, %ca})
            !! do {
                my $s = Supplier::Preserving.new;
                $connector.establish($in.Supply, :$host, :$port, |{%tls-config, %ca}).tap:
                    { $s.emit($_) },
                    done => { $s.done },
                    quit => {
                        try $version-decision.break($_);
                        $s.quit($_);
                    };
                $s.Supply
            };
        $version-decision.then: -> $version {
            $version.result eq '2'
                ?? Pipeline2.new(:$secure, :$host, :$port, :$in, :$out)
                !! Pipeline.new(:$secure, :$host, :$port, :$in, :$out)
        }
    }

    method !assemble-request(Str $method, Cro::Uri $url, %options --> Cro::HTTP::Request) {
        my $target = $url.path || '/';
        $target ~= "?{$url.query}" if $url.query;
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
            when 'cookies' {
                for $value.list {
                    when Cro::HTTP::Cookie {
                        $request.add-cookie($_);
                    }
                    when Pair {
                        $request.add-cookie(.key, .value);
                    }
                    default {
                        die X::Cro::HTTP::Client::InvalidCookie.new(bad => $_);
                    }
                }
            }
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
