use Cro;
use Cro::HTTP::Client;

class Cro::HTTP::ReverseProxy does Cro::Transform {
    has $.to;
    has $!client = Cro::HTTP::Client.new;

    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Response }

    method transformer(Supply $pipeline --> Supply) {
        $!to .= substr(0, *-1) if $!to.ends-with('/');
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

            try {
                emit (await $!client.request($request.method, "{$!to}/$target", %options));
            }
            CATCH {
                default {
                    .note
                }
            }
        }
    }
}
