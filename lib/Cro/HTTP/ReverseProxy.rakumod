use Cro;
use Cro::HTTP::Client;

class X::Cro::HTTP::ReverseProxy::InvalidSettings is Exception {
    has $.msg;

    method message { $!msg }
}

class Cro::HTTP::ReverseProxy does Cro::Transform {
    subset ReverseProxyLink where Str|Callable;

    has ReverseProxyLink $.to;
    has Str $.to-absolute;
    has ReverseProxyLink $!destination;
    has Cro::HTTP::Client $!client;
    has &.request;
    has &.response;
    has %.ca;

    submethod TWEAK() {
        unless $!to.defined ^^ $!to-absolute.defined {
            die X::Cro::HTTP::ReverseProxy::InvalidSettings
                    .new(msg => 'Either `to` or `to-absolute` must be specified for ReverseProxy');
        }
        $!to = self!trim-url($!to) if $!to ~~ Str:D;
        $!to-absolute = self!trim-url($_) with $!to-absolute;
        with $!to {
            die X::Cro::HTTP::ReverseProxy::InvalidSettings
                    .new(msg => '`to` of ReverseProxy must be a Str or code block') unless $!to ~~ ReverseProxyLink;
            $!destination = $!to;
        }
        else {
            $!destination = $!to-absolute;
        }

        my %args = %!ca ?? (:%!ca, :http<1.1 2>) !! ();
        $!client = Cro::HTTP::Client.new(|%args);
    }

    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Response }

    method !trim-url($url) { $url.ends-with('/') ?? $url.substr(0, *- 1) !! $url }

    method transformer(Supply $pipeline --> Supply) {
        supply whenever $pipeline -> $request {
            my $proxy-state;
            sub get-options($request) {
                supply {
                    if $request.has-body {
                        whenever $request.body -> $body {
                            emit %(headers => $request.headers, :$body);
                            done;
                        }
                    } else {
                        emit %(headers => $request.headers);
                        done;
                    }
                }
            }

            sub send($request) {
                whenever get-options($request) -> $options {
                    whenever self!make-destination($request) -> $dest {
                        whenever $!client.request($request.method, $dest, |$options) -> $response {
                            my $*PROXY-STATE := $proxy-state;
                            my $res = &!response ?? &!response($response) !! $response;
                            $res = $response unless $res.defined && $res ~~ Cro::HTTP::Response;
                            if $res ~~ Awaitable {
                                whenever $res { emit $_ }
                            } else {
                                emit $res;
                            }
                        }
                    }
                }
            }

            unless $request ~~ Cro::HTTP::Request {
                die "Request middleware { self.^name } emitted a $request.^name(), " ~
                        "but a Cro::HTTP::Request object was required";
            }

            my $*PROXY-STATE := $proxy-state;
            my $req = &!request ?? &!request($request) !! $request;
            $req = $request unless $req.defined && $req ~~ Cro::HTTP::Request;
            if $req ~~ Awaitable {
                whenever $req { send($req) }
            } else {
                send($req);
            }
        }
    }

    method !make-destination(Cro::HTTP::Request $request) {
        my $target = $request.target;
        $target .= substr(1 .. *) if $target.starts-with('/');
        if $!destination ~~ Str {
            return Promise.kept($!to ?? "{$!destination}/$target" !! $!to-absolute);
        } else {
            my $dest-p = $!destination($request);
            if $dest-p ~~ Awaitable {
                return $dest-p.then({.status ~~ Kept ?? do {
                    my $url = self!trim-url(.result);
                    $!to ?? "$url/$target" !! "$url"
                } !! die 'Failed to get URL' });
            } else {
                my $tmp = self!trim-url($dest-p);
                return Promise.kept($!to ?? "$tmp/$target" !! $tmp);
            }
        }
    }
}
