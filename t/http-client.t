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
        post -> {
            content 'text/plain', 'Updated';
        }
        put -> {
            content 'text/plain', 'Saved';
        }
        delete -> {
            content 'text/plain', 'Gone';
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
        ok $resp ~~ Crow::HTTP::Response, 'Got a response back from GET /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Home', 'Body text is correct';
    }

    given await Crow::HTTP::Client.post("$base/") -> $resp {
        ok $resp ~~ Crow::HTTP::Response, 'Got a response back from POST /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Updated', 'Body text is correct';
    }

    given await Crow::HTTP::Client.put("$base/") -> $resp {
        ok $resp ~~ Crow::HTTP::Response, 'Got a response back from PUT /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Saved', 'Body text is correct';
    }

    given await Crow::HTTP::Client.delete("$base/") -> $resp {
        ok $resp ~~ Crow::HTTP::Response, 'Got a response back from DELETE /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Gone', 'Body text is correct';
    }

    given await Crow::HTTP::Client.get("$base/") -> $resp {
        is await($resp.body-blob).list, 'Home'.encode('ascii').list,
            'Can also get body back as a blob';
    }
}

done-testing;
