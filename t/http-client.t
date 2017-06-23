use Cro::HTTP::Response;
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
    use Cro::HTTP::Router;
    use Cro::HTTP::Server;

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
        get -> 'path', :$User-agent! is header {
            content 'text/plain', "When you are $User-agent, it is fine to request";
        }
    }

    my $http-server = Cro::HTTP::Server.new(
        port => HTTP_TEST_PORT,
        application => $app
    );
    $http-server.start();
    END $http-server.stop();

    my $https-server = Cro::HTTP::Server.new(
        port => HTTPS_TEST_PORT,
        application => $app,
        ssl => %key-cert
    );
    $https-server.start();
    END $https-server.stop();
}

{
    use Cro::HTTP::Client;
    my $base = "http://localhost:{HTTP_TEST_PORT}";

    given await Cro::HTTP::Client.get("$base/") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from GET /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Home', 'Body text is correct';
    }

    given await Cro::HTTP::Client.post("$base/") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from POST /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Updated', 'Body text is correct';
    }

    given await Cro::HTTP::Client.put("$base/") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from PUT /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Saved', 'Body text is correct';
    }

    given await Cro::HTTP::Client.delete("$base/") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from DELETE /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Gone', 'Body text is correct';
    }

    given await Cro::HTTP::Client.get("$base/") -> $resp {
        is await($resp.body-blob).list, 'Home'.encode('ascii').list,
            'Can also get body back as a blob';
    }

    my %body = :truth, :!lie;
    given await Cro::HTTP::Client.get("$base/",
                                      content-type => 'application/json',
                                      body => %body) -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response from GET / with JSON';
    }

    my $client = Cro::HTTP::Client.new(headers => [ User-agent => 'Cro' ]);
    given await $client.get("$base/path") -> $resp {
        is await($resp.body-text), 'When you are Cro, it is fine to request', 'Default headers were sent';
    }

    $client = Cro::HTTP::Client.new(headers => [ 1 ]);
    throws-like { $client.get("$base/path") }, X::Cro::HTTP::Client::IncorrectHeaderType,
        'Client header can only be Pair or Cro::HTTP::Header instance';
}

done-testing;

