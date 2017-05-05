use Crow::HTTP::Client;
use Crow::HTTP::Response;
use Test;

constant HTTP_TEST_PORT = 31316;
constant HTTPS_TEST_PORT = 31317;
constant %ca := { ca-file => 't/certs-and-keys/ca-crt.pem' };
constant %key-cert := {
    private-key-file => 't/certs-and-keys/server-key.pem',
    certificate-file => 't/certs-and-keys/server-crt.pem'
};

# Test application.
{
    use Crow::HTTP::Router;
    use Crow::HTTP::Server;

    my $app = route {
        get -> {
            content 'text/plain', 'Home';
        }
    }

    my $http-server = Crow::HTTP::Server.new(
        port => HTTP_TEST_PORT,
        application => $app
    );
    $http-server.start();
    END $http-server.stop();

    my $https-server = Crow::HTTP::Server.new(
        port => HTTPS_TEST_PORT,
        application => $app,
        ssl => %key-cert
    );
    $https-server.start();
    END $https-server.stop();
}

{
    my $base = "http://localhost:{HTTP_TEST_PORT}";
    given await Crow::HTTP::Client.get("$base/") -> $resp {
        ok $resp ~~ Crow::HTTP::Response, 'Got a response back from /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
    }
}

done-testing;
