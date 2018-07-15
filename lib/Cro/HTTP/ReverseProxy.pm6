use Cro;
use Cro::HTTP::Client;

class Cro::HTTP::ReverseProxy does Cro::Transform {
    has $.to;
    has $.to-absolute;
    has $!destination;
    has $!client = Cro::HTTP::Client.new;

    submethod TWEAK() {
        unless ($!to.defined ^^ $!to-absolute.defined) {
            die 'Either `to` or `to-absolute` must be specified for ReverseProxy';
        }
        $!to = self!trim-url($!to) if $!to ~~ Str;
        $!to-absolute = self!trim-url($!to-absolute) if $!to-absolute ~~ Str;
        with $!to {
            die '`to` of ReverseProxy must be a Str or code block' unless $!to ~~ Str|Callable;
            $!destination = $!to;
        }
        else {
            $!destination = $!to-absolute;
        }
    }

    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Response }

    method !trim-url($url) { $url.ends-with('/') ?? $url.substr(0, *-1) !! $url }

    method transformer(Supply $pipeline --> Supply) {
        supply whenever $pipeline -> $request {
            unless $request ~~ Cro::HTTP::Request {
                die "Request middleware {self.^name} emitted a $request.^name(), " ~
                    "but a Cro::HTTP::Request was required";
            }
            my %options = headers => $request.headers;
            %options<body> = await $request.body if $request.has-body;

            my $target = $request.target;
            $target .= substr(1..*) if $target.starts-with('/');
            my $forward;
            if $!destination ~~ Str {
                $forward = $!to ?? "{$!destination}/$target" !! $!to-absolute;
            } else {
                my $tmp = self!trim-url($!destination($request));
                $forward = $!to ?? "$tmp/$target" !! $tmp;
            }

            emit (await $!client.request($request.method, $forward, %options));
        }
    }
}
