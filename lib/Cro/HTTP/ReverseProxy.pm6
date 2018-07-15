use Cro;
use Cro::HTTP::Client;

class Cro::HTTP::ReverseProxy does Cro::Transform {
    has $.to;
    has $.to-absolute;
    has $!client = Cro::HTTP::Client.new;

    submethod TWEAK() {
        unless ($!to.defined ^^ $!to-absolute.defined) {
            die 'Either `to` or `to-absolute` must be specified for ReverseProxy';
        }
    }

    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Response }

    method transformer(Supply $pipeline --> Supply) {
        with $!to {
            $!to .= substr(0, *-1) if $!to.ends-with('/');
        }
        with $!to-absolute {
            $!to-absolute .= substr(0, *-1) if $!to-absolute.ends-with('/');
        }
        supply whenever $pipeline -> $request {
            unless $request ~~ Cro::HTTP::Request {
                die "Request middleware {self.^name} emitted a $request.^name(), " ~
                    "but a Cro::HTTP::Request was required";
            }
            my %options;
            %options<headers> = $request.headers;
            %options<body> = await $request.body if $request.has-body;

            my $target = $request.target;
            $target .= substr(1..*) if $target.starts-with('/');
            my $forward = $!to ?? "{$!to}/$target" !! $!to-absolute;

            try {
                emit (await $!client.request($request.method, $forward, %options));
            }
            CATCH {
                default {
                    .note
                }
            }
        }
    }
}
