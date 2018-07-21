use Cro::HTTP::Client;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Cro::TLS;
use Test;

if supports-alpn() {
    constant TEST_PORT = 31290;
    my $base = "https://localhost:{TEST_PORT}";
    constant %ca := { ca-file => 't/certs-and-keys/ca-crt.pem' };
    constant %key-cert := {
        private-key-file => 't/certs-and-keys/server-key.pem',
        certificate-file => 't/certs-and-keys/server-crt.pem'
    };

    my $application = route {
        post -> {
            request-body -> (:$foo, *%) {
                content 'text/html', "Answer";
            }
        }
    }

    my Cro::Service $http = Cro::HTTP::Server.new:
    http => <2>, port => TEST_PORT, tls => %key-cert, :$application;

    $http.start;
    END $http.stop;

    given await Cro::HTTP::Client.post("$base/", :%ca,
                                       content-type => 'application/x-www-form-urlencoded',
                                       body => foo => 42) -> $resp {
        is await($resp.body-text), 'Answer', 'HTTP/2 server can parse body';
    };
} else {
    skip 'No ALPN support', 1;
}

done-testing;
