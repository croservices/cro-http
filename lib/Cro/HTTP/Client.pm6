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
        "Incorrect header of type {$.what.^name} was passed to Client"
    }
}

class Cro::HTTP::Client {
    has @.headers;
    has $.cookie-jar;
    has $.body-serializers;
    has $.add-body-serializers;
    has $.body-parsers;
    has $.add-body-parsers;
    has $.content-type;

    submethod BUILD(:$cookie-jar, :@!headers, :$!content-type,
                    :$!body-serializers, :$!add-body-serializers,
                    :$!body-parsers, :$!add-body-parsers) {
        when $cookie-jar ~~ Bool {
            $!cookie-jar = Cro::HTTP::Client::CookieJar.new;
        }
        when $cookie-jar ~~ Cro::HTTP::Client::CookieJar {
            $!cookie-jar = $cookie-jar;
        }
        # throw?
    }

    multi method get($url, %options --> Supply) {
        self.request('GET', $url, %options)
    }
    multi method get($url, *%options --> Supply) {
        self.request('GET', $url, %options)
    }

    multi method head($url, %options --> Supply) {
        self.request('HEAD', $url, %options)
    }
    multi method head($url, *%options --> Supply) {
        self.request('HEAD', $url, %options)
    }

    multi method post($url, %options --> Supply) {
        self.request('POST', $url, %options)
    }
    multi method post($url, *%options --> Supply) {
        self.request('POST', $url, %options)
    }

    multi method put($url, %options --> Supply) {
        self.request('PUT', $url, %options)
    }
    multi method put($url, *%options --> Supply) {
        self.request('PUT', $url, %options)
    }

    multi method delete($url, %options --> Supply) {
        self.request('DELETE', $url, %options)
    }
    multi method delete($url, *%options --> Supply) {
        self.request('DELETE', $url, %options)
    }

    my class Pipeline {
        has Supplier $.in;
        has Supply $.out;
    }

    multi method request(Str $method, $url, *%options --> Supply) {
        self.request($method, $url, %options)
    }
    multi method request(Str $method, $url, %options --> Supply) {
        my $parsed-url = $url ~~ Cro::Uri ?? $url !! Cro::Uri.parse(~$url);
        my $pipeline = self!get-pipeline($parsed-url);
        my $request-object = self!assemble-request($method, $parsed-url, %options);
        $pipeline.in.emit($request-object);
        $pipeline.in.done();
        supply {
            whenever $pipeline.out {
                if .status < 400 {
                    $.cookie-jar.add-from-response($_,
                                                   $parsed-url) if self && $.cookie-jar.defined;
                    .emit
                } elsif .status >= 500 {
                    die X::Cro::HTTP::Error::Server.new(response => $_);
                } else {
                    die X::Cro::HTTP::Error::Client.new(response => $_);
                }
            }
        }
    }

    method !get-pipeline(Cro::Uri $url) {
        my $secure = $url.scheme.lc eq 'https';
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
        my $out = $connector.establish($in.Supply,
            host => $url.host,
            port => $url.port // ($secure ?? 443 !! 80));
        return Pipeline.new(:$in, :$out)
    }

    method !assemble-request(Str $method, Cro::Uri $url, %options --> Cro::HTTP::Request) {
        my $target = $url.path || '/';
        my $request = Cro::HTTP::Request.new(:$method, :$target);
        $request.append-header('Host', $url.host);
        if self {
            $request.append-header('content-type', $.content-type) if $.content-type;
            self!set-headers($request, @.headers.List);
            $.cookie-jar.add-to-request($request, $url) if $.cookie-jar;
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
        }
        return $request;
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
