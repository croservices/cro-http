use Cro::HTTP::Client;
use Cro::HTTP::Server;
use Cro::SSL;
use Test;

plan 2;

skip-rest "ALPN is not supported" unless supports-alpn;

class MyServer does Cro::Transform {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Response }

    method transformer($request-stream) {
        supply {
            whenever $request-stream -> $request {
                given Cro::HTTP::Response.new(:200status, :$request) {
                    .append-header('content-type', 'text/html');
                    .set-body("Response");
                    .emit;
                }
            }
        }
    }
}

constant %ca := { ca-file => 't/certs-and-keys/ca-crt.pem' };
constant %ssl := {
    private-key-file => 't/certs-and-keys/server-key.pem',
    certificate-file => 't/certs-and-keys/server-crt.pem'
};

my Cro::Service $http2-service = Cro::HTTP::Server.new(
    :http<2>, :host<localhost>, :port(8000), :%ssl,
    :application(MyServer)
);

$http2-service.start;
END { $http2-service.stop; }

my $client = Cro::HTTP::Client.new(:http<2>);

given $client.get("https://localhost:8000", :%ca) -> $resp {
    my $res = await $resp;
    is (await $res.body), 'Response', 'HTTP/2 response is get';
}

my $lock = Lock.new;
my $p = Promise.new;
my $counter = 0;
for ^3 {
    start {
        given $client.get("https://localhost:8000", :%ca) -> $resp {
            my $res = await $resp;
            my $body = await $res.body-text;
            $lock.protect({ $counter++; $p.keep if $counter == 3; });
        }
    }
}

await Promise.anyof($p, Promise.in(2));

is $counter, 3, 'Concurrent responses are handled';
