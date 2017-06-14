use Cro::HTTP::Request;
use Cro::HTTP::RequestSerializer;
use Cro::HTTP::ResponseParser;
use Cro::TCP;
use Cro::SSL;
use Cro::Uri;
use Cro;

class Cro::HTTP::Client {
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
        my Bool $body-set = False;
        for %options.kv -> $key, $value {
            when $key ~~ 'body' {
                if !$body-set {
                    # $request.append-header('Content-type', %options<content-type>);
                    # throw if Content-type is not set?
                    $request.set-body($value);
                    $body-set = True;
                } else {
                    # throw?
                }
            }
            when $key ~~ 'body-byte-stream' {
                if !$body-set {
                    # $request.append-header('Content-type', %options<content-type>);
                    # throw if Content-type is not set?
                    $request.set-body-byte-stream($value);
                    $body-set = True;
                } else {
                    # throw?
                }
            }
            when $key ~~ 'content-type' {
                $request.append-header('content-type', $value)
            }
            when $key ~~ 'headers' {
                if $key ~~ Iterable {
                    for $key.List -> $header {
                        when $header ~~ Pair {
                            $request.append-header($header.key, $header.value)
                        }
                        when $header ~~ Cro::HTTP::Header {
                            $request.append-header($header)
                        }
                        default {
                            # throw?
                        }
                    }
                }
}
        }
        return $request;
    }
}
