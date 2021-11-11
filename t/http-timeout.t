use Cro::HTTP::Client;
use Cro::Policy::Timeout;
use Test;

constant HTTP_TEST_PORT = 31326;
constant HTTPS_TEST_PORT = 31327;

constant %ca := { ca-file => 't/certs-and-keys/ca-crt.pem' };
constant %tls := {
    private-key-file => 't/certs-and-keys/server-key.pem',
    certificate-file => 't/certs-and-keys/server-crt.pem'
};

# Test application
{
    use Cro::HTTP::Router;
    use Cro::HTTP::Server;

    my $application = route {
        get -> Int :$t {
            sleep $t;
            content 'text/plain', 'Response';
        }

        get -> 'body', Int :$t {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body(supply {
                emit "<html>".encode;
                sleep $t;
                emit "</html>".encode;
                done;
            });
        }
    }

    my $http-server = Cro::HTTP::Server.new(
        port => HTTP_TEST_PORT, :$application
    );
    $http-server.start();
    END $http-server.stop();

    # HTTP/2 instance
    my $http2-server = Cro::HTTP::Server.new(
        port => HTTPS_TEST_PORT, :$application, :%tls, :http<2>
    );
    $http2-server.start();
    END $http2-server.stop();
}

{
    throws-like {
        given await Cro::HTTP::Client.get("http://localhost:{ HTTP_TEST_PORT }/?t=3",
                timeout => 1) -> $resp {
            say await $resp.body-text;
        }
    }, X::Cro::HTTP::Client::Timeout, message => /'headers'/, 'Timeout for headers via total';
    throws-like {
        given await Cro::HTTP::Client.get("https://localhost:{ HTTPS_TEST_PORT }/?t=3",
                timeout => 1, :http<2>, :%ca) -> $resp {
            say await $resp.body-text;
        }
    }, X::Cro::HTTP::Client::Timeout, message => /'headers'/, 'Timeout for headers via total for HTTP/2';
}

{
    throws-like {
        given await Cro::HTTP::Client.get("http://localhost:{ HTTP_TEST_PORT }/?t=3",
                timeout => %( headers => 1 )) -> $resp {
            say await $resp.body-text;
        }
    }, X::Cro::HTTP::Client::Timeout, message => /'localhost:31326'/, 'Timeout for headers via phase';
}

{
    given await Cro::HTTP::Client.get("http://localhost:{ HTTP_TEST_PORT }/body?t=3",
            timeout => %( headers => Inf, body => 1 )) -> $resp {
            throws-like {
                 say await $resp.body-text;
            }, X::Cro::HTTP::Client::Timeout, message => /'body'/, 'Timeout for body';
    }
    given await Cro::HTTP::Client.get("https://localhost:{ HTTPS_TEST_PORT }/body?t=3",
            timeout => %( headers => Inf, body => 1 ), :%ca, :http<2>) -> $resp {
        throws-like {
            say await $resp.body-text;
        }, X::Cro::HTTP::Client::Timeout, message => /'body'/, 'Timeout for body for HTTP/2';
    }
}

{
    given await Cro::HTTP::Client.get("http://localhost:{ HTTP_TEST_PORT }/body?t=3",
            timeout => 1) -> $resp {
        throws-like {
            say await $resp.body-text;
        }, X::Cro::HTTP::Client::Timeout, message => /'body'/, 'Total timeout works for body also';
    }
}

{
    given await Cro::HTTP::Client.get("http://localhost:{ HTTP_TEST_PORT }/body?t=0",
            timeout => %( headers => Inf, body => 3 )) -> $resp {
        lives-ok { await $resp.body-text }, 'No issues if the timeout does not expire';
    }
}

{
    class Cro::Fake::Connector does Cro::Connector {
        method consumes() { Cro::TCP::Message }
        method produces() { Cro::TCP::Message }

        method connect(:$nodelay, *%options --> Promise) {
            Promise.in(10);
        }
    }

    class Cro::HTTP::Client::InfiniteConnection is Cro::HTTP::Client {
        method choose-connector($secure) { Cro::Fake::Connector }
    }

    throws-like {
        await Cro::HTTP::Client::InfiniteConnection.get("http://localhost:{ HTTP_TEST_PORT }/", timeout => %( connection => 1 ));
    }, X::Cro::HTTP::Client::Timeout, message => /'connection'/, 'Timeout for connection';
}

done-testing;
