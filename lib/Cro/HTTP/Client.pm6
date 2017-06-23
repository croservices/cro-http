use Cro::HTTP::Header;
use Cro::HTTP::Request;
use Cro::HTTP::RequestSerializer;
use Cro::HTTP::ResponseParser;
use Cro::TCP;
use Cro::SSL;
use Cro::Uri;
use Cro;

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
        return $pipeline.out;
    }

    method !get-pipeline(Cro::Uri $url) {
        my $secure = $url.scheme.lc eq 'https';
        my $connector = Cro.compose(
            Cro::HTTP::RequestSerializer.new,
            $secure ?? Cro::SSL::Connector !! Cro::TCP::Connector,
            Cro::HTTP::ResponseParser.new);
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
        self!set-headers($request, @.headers.List) if self;
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
                self!set-headers($request, $_.List) if $_ ~~ Iterable;
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
