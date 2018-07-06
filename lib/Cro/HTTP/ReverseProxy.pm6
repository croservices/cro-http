use Cro;
use Cro::HTTP::Client;

class Cro::HTTP::ReverseProxy does Cro::Transform {
    has $.to;
    has $!client = Cro::HTTP::Client.new;

    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Response }

    # submethod BUILD(:$!to) {}

    method transformer(Supply $pipeline --> Supply) {
        supply whenever $pipeline -> $request {
            unless $request ~~ Cro::HTTP::Request {
                die "Request middleware {self.^name} emitted a $request.^name(), " ~
                    "but a Cro::HTTP::Request was required";
            }
            my %options;
            %options<headers> = $request.headers;
            %options<body> = await $request.body if $request.has-body;
            emit (await $!client.request($request.method, $!to, %options));
        }
    }
}
