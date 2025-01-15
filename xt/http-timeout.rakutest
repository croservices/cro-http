use Cro::HTTP::Client;
use Cro::Policy::Timeout;
use Cro::UnhandledErrorReporter;
use Test;

constant HTTP_TEST_PORT = 31326;
constant HTTPS_TEST_PORT = 31327;

constant %ca := { ca-file => 'xt/certs-and-keys/ca-crt.pem' };
constant %tls := {
    private-key-file => 'xt/certs-and-keys/server-key.pem',
    certificate-file => 'xt/certs-and-keys/server-crt.pem'
};

# Suppress any unhandled errors so they don't end up in the test output.
set-unhandled-error-reporter -> $ {}

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
            await $resp.body-text;
        }
    }, X::Cro::HTTP::Client::Timeout, message => /'headers'/, 'Timeout for headers via total';
    throws-like {
        given await Cro::HTTP::Client.get("https://localhost:{ HTTPS_TEST_PORT }/?t=3",
                timeout => 1, :http<2>, :%ca) -> $resp {
            await $resp.body-text;
        }
    }, X::Cro::HTTP::Client::Timeout, message => /'headers'/, 'Timeout for headers via total for HTTP/2';
}

{
    throws-like {
        given await Cro::HTTP::Client.get("http://localhost:{ HTTP_TEST_PORT }/?t=3",
                timeout => %( headers => 1 )) -> $resp {
            await $resp.body-text;
        }
    }, X::Cro::HTTP::Client::Timeout, message => /'localhost:31326'/, 'Timeout for headers via phase';
}

{
    given await Cro::HTTP::Client.get("http://localhost:{ HTTP_TEST_PORT }/body?t=3",
            timeout => %( headers => Inf, body => 1 )) -> $resp {
            throws-like {
                 await $resp.body-text;
            }, X::Cro::HTTP::Client::Timeout, message => /'body'/, 'Timeout for body';
    }
    given await Cro::HTTP::Client.get("https://localhost:{ HTTPS_TEST_PORT }/body?t=3",
            timeout => %( headers => Inf, body => 1 ), :%ca, :http<2>) -> $resp {
        throws-like {
            await $resp.body-text;
        }, X::Cro::HTTP::Client::Timeout, message => /'body'/, 'Timeout for body for HTTP/2';
    }
    my $c = Cro::HTTP::Client.new(:%ca, :http<2>);
    my @promises;
    race for 0, 0, 0, 5, 0, 0, 0 -> $timeout {
        @promises.push: $c.get("https://localhost:{ HTTPS_TEST_PORT }/body?t=$timeout", timeout => %( body => 1 ));
    }
    my $count;
    react {
        for @promises -> $p {
            whenever $p {
                given $_ -> $resp {
                    if $resp.request.target.ends-with('5') {
                        throws-like {
                            await $resp.body-text
                        }, X::Cro::HTTP::Client::Timeout, message => /'body'/;
                    } else {
                        $count++;
                        lives-ok { await $resp.body-text }, 'Could live in concurrent env';
                        done if $count == 5;
                    }
                }
            }
        }
    }
    is $count, 5, 'Concurrent HTTP/2 test is alright';
}

{
    my $c = Cro::HTTP::Client.new(timeout => %( headers => Inf, body => 1 ));
    given await $c.get("http://localhost:{ HTTP_TEST_PORT }/body?t=2") -> $resp {
        throws-like {
            await $resp.body-text;
        }, X::Cro::HTTP::Client::Timeout, message => /'body'/, 'Timeout set to the client works';
    }
    $c = Cro::HTTP::Client.new(timeout => %( headers => Inf, body => 1 ));
    given await $c.get("http://localhost:{ HTTP_TEST_PORT }/body?t=2", timeout => %( body => 5 )) -> $resp {
        lives-ok {
            await $resp.body-text;
        }, 'Timeout set to client is overriden by request one';
    }
}

{
    given await Cro::HTTP::Client.get("http://localhost:{ HTTP_TEST_PORT }/body?t=3",
            timeout => 1) -> $resp {
        throws-like {
            await $resp.body-text;
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
