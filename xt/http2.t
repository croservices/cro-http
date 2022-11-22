use Cro::HTTP::Client;
use Cro::HTTP::Server;
use Cro::TLS;
use Test;

plan 6;

unless supports-alpn() {
    skip-rest "ALPN is not supported";
    exit 0;
}

class MyServer does Cro::Transform {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Response }

    method transformer($request-stream) {
        supply {
            whenever $request-stream -> $request {
                subtest {
                    ok $request.header('Host').defined;
                    ok $request.uri.host eq 'localhost';
                }, 'HTTP/2 pseudo-headers are propagated correctly';
                given Cro::HTTP::Response.new(:200status, :$request) {
                    .append-header('content-type', 'text/html');
                    .set-body("Response");
                    .emit;
                }
            }
        }
    }
}

constant %ca := { ca-file => 'xt/certs-and-keys/ca-crt.pem' };
constant %tls := {
    private-key-file => 'xt/certs-and-keys/server-key.pem',
    certificate-file => 'xt/certs-and-keys/server-crt.pem'
};

my constant TEST_PORT = 31325;
my Cro::Service $http2-service = Cro::HTTP::Server.new:
        :http<2>, :host<localhost>, :port(TEST_PORT), :%tls,
        :application(MyServer);

$http2-service.start;
END try $http2-service.stop;

my $client = Cro::HTTP::Client.new(:http<2>);

given $client.get("https://localhost:{TEST_PORT}", :%ca) -> $resp {
    my $res = await $resp;
    is (await $res.body), 'Response', 'HTTP/2 response is get';
}

my $lock = Lock.new;
my $p = Promise.new;
my $counter = 0;
for ^3 {
    start {
        given $client.get("https://localhost:{TEST_PORT}", :%ca) -> $resp {
            my $res = await $resp;
            my $body = await $res.body-text;
            $lock.protect({ $counter++; $p.keep if $counter == 3; });
        }
    }
}

await Promise.anyof($p, Promise.in(2));
is $counter, 3, 'Concurrent responses are handled';
