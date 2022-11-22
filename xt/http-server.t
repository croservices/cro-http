use Cro::HTTP::Router;
use Cro;
use Cro::HTTP::Request;
use Cro::HTTP::Response;
use Cro::HTTP::Client;
use Cro::HTTP::Server;
use Cro::Transform;
use Cro::UnhandledErrorReporter;
use IO::Socket::Async::SSL;
use Test;

# Suppress any unhandled errors so they don't end up in the test output and
# confuse folks.
set-unhandled-error-reporter -> $ {}

constant TEST_PORT = 31314;
my $base = "http://localhost:{TEST_PORT}";

class TestHttpApp does Cro::Transform {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Response }

    method transformer($request-stream) {
        supply {
            whenever $request-stream -> $request {
                given Cro::HTTP::Response.new(:200status, :$request) {
                    .append-header('Content-type', 'text/html');
                    .set-body("<strong>Hello from Cro!</strong>".encode('ascii'));
                    .emit;
                }
            }
        }
    }
}

{
    my $service = Cro::HTTP::Server.new(
        port => TEST_PORT,
        application => TestHttpApp
    );
    ok $service ~~ Cro::Service, 'Service does Cro::Service';
    dies-ok { await IO::Socket::Async.connect('localhost', TEST_PORT) },
        'Server not listening until started';
    lives-ok { $service.start }, 'Can start service';

    my $conn;
    lives-ok { $conn = await IO::Socket::Async.connect('localhost', TEST_PORT) },
        'Can connect once service is started';
    await $conn.print("GET / HTTP/1.0\r\n\r\n");
    my $response = '';
    my $timed-out = False;
    react {
        whenever $conn {
            $response ~= $_;
            LAST done;
        }
        whenever Promise.in(5) {
            $timed-out = True;
            done;
        }
    }
    $conn.close;
    nok $timed-out, 'Got a response from the server';
    like $response, /^ HTTP \N+ 200/,
        'Response has 200 status in it';
    like $response, /"<strong>Hello from Cro!</strong>"/,
        'Response contains expected body';

    lives-ok { $service.stop }, 'Can stop service';
    dies-ok { await IO::Socket::Async.connect('localhost', TEST_PORT) },
        'Server not listening after stopped';
}

{
    constant %ca := { ca-file => 'xt/certs-and-keys/ca-crt.pem' };
    constant %key-cert := {
        private-key-file => 'xt/certs-and-keys/server-key.pem',
        certificate-file => 'xt/certs-and-keys/server-crt.pem'
    };

    my $service = Cro::HTTP::Server.new(
        port => TEST_PORT,
        tls => %key-cert,
        application => TestHttpApp
    );
    ok $service ~~ Cro::Service, 'Service does Cro::Service (HTTPS)';
    dies-ok { await IO::Socket::Async::SSL.connect('localhost', TEST_PORT, |%ca) },
        'Server not listening until started (HTTPS)';
    lives-ok { $service.start }, 'Can start service (HTTPS)';

    my $conn;
    lives-ok { $conn = await IO::Socket::Async::SSL.connect('localhost', TEST_PORT, |%ca) },
        'Can connect once service is started (HTTPS)';
    await $conn.print("GET / HTTP/1.0\r\n\r\n");
    my $response = '';
    my $timed-out = False;
    react {
        whenever $conn {
            $response ~= $_;
            LAST done;
        }
        whenever Promise.in(5) {
            $timed-out = True;
            done;
        }
    }
    $conn.close;
    nok $timed-out, 'Got a response from the server (HTTPS)';
    like $response, /^ HTTP \N+ 200/,
        'Response has 200 status in it (HTTPS)';
    like $response, /"<strong>Hello from Cro!</strong>"/,
        'Response contains expected body (HTTPS)';

    lives-ok { $service.stop }, 'Can stop service (HTTPS)';
    dies-ok { await IO::Socket::Async::SSL.connect('localhost', TEST_PORT, |%ca) },
        'Server not listening after stopped (HTTPS)';
}

# Parsing

{
    my $app = route {
        get -> {
            request-body -> %object {
                content 'text/plain', "Cannot be seen";
            }
        }
    }

    my Cro::Service $test = Cro::HTTP::Server.new(
        :host('localhost'), :port(TEST_PORT), application => $app,
        body-parsers => []);

    $test.start();
    LEAVE $test.stop();

    my %body = :42x, :101y;

    throws-like { await Cro::HTTP::Client.get("$base/",
                                              content-type => 'application/json',
                                              :%body) },
        X::Cro::HTTP::Error::Client,
        'Server with empty body-parsers cannot parse requests';
}

{
    my $app = route {
        get -> {
            request-body -> %object {
                content 'text/plain', "pair: x is %object<x>, y is %object<y>";
            }
        }
    }

    my Cro::Service $test = Cro::HTTP::Server.new(
        :host('localhost'), :port(TEST_PORT), application => $app,
        body-parsers => [Cro::HTTP::BodyParser::JSON.new]);

    $test.start();
    LEAVE $test.stop();

    my %body = :42x, :101y;

    given await Cro::HTTP::Client.get("$base/",
                                      content-type => 'application/json',
                                      body => %body) -> $resp {
        is await($resp.body-text), 'pair: x is 42, y is 101', 'Response body text is correct';
    };

    throws-like { await Cro::HTTP::Client.get("$base/",
                                              content-type => 'text/plain',
                                              body => "Aokigahara") },
        X::Cro::HTTP::Error::Client,
        'Request with incorrect content-type is rejected';
}

{
    my $app = route {
        get -> {
            request-body
            'application/json' => -> %object {
                content 'text/plain', "pair: x is %object<x>, y is %object<y>";
            },
            'text/plain' => -> $text {
                content 'text/plain', "$text";
            }
        }
    }

    my Cro::Service $test = Cro::HTTP::Server.new(
        :host('localhost'), :port(TEST_PORT), application => $app,
        body-parsers => [Cro::HTTP::BodyParser::JSON.new],
        add-body-parsers => [Cro::HTTP::BodyParser::TextFallback.new]);

    $test.start();
    LEAVE $test.stop();

    given await Cro::HTTP::Client.get("$base/",
                                      content-type => 'text/plain',
                                      body => 'Zuriaake') -> $resp {
        subtest {
            is (await $resp.body), 'Zuriaake';
            is $resp.status, 200;
        }, 'Request for additional parser is processed';
    };
}

# Serializing

{
    my $app = route {
        get -> {
            request-body 'text/plain' => -> $text {
                content 'text/plain', 'Hands That Lift the Oceans';
            }
        }
    }

    my Cro::Service $test = Cro::HTTP::Server.new(
        :host('localhost'), :port(TEST_PORT), application => $app,
        body-serializers => []);

    $test.start();
    LEAVE $test.stop();

    throws-like { await Cro::HTTP::Client.get("$base/",
                                        content-type => 'text/plain',
                                        body => 'give-me-text') },
        X::Cro::HTTP::Error::Server,
        'Request to server without serializers ends up with 500 error';
}

{
    my $app = route {
        get -> {
            request-body 'text/plain' => -> $text {
                if $text eq 'give-me-text' {
                    content 'text/plain', 'Hands That Lift the Oceans';
                } else {
                    content 'application/json', {:42answer};
                }
            }
        }
    }

    my Cro::Service $test = Cro::HTTP::Server.new(
        :host('localhost'), :port(TEST_PORT), application => $app,
        body-serializers => [Cro::HTTP::BodySerializer::StrFallback.new]);

    $test.start();
    LEAVE $test.stop();

    given await Cro::HTTP::Client.get("$base/",
                                      content-type => 'text/plain',
                                      body => 'give-me-text') -> $resp {
        subtest {
            is (await $resp.body), 'Hands That Lift the Oceans';
            is $resp.status, 200;
        }, 'Request for one serializer is processed';
    };

    throws-like { await Cro::HTTP::Client.get("$base/",
                                              content-type => 'text/plain',
                                              body => 'give-me-json') },
        X::Cro::HTTP::Error::Server,
        'Request without a serializer gives error';
}

{
    my $app = route {
        get -> {
            request-body 'text/plain' => -> $text {
                if $text eq 'give-me-text' {
                    content 'text/plain', 'Hands That Lift the Oceans';
                } else {
                    content 'application/json', {:42answer};
                }
            }
        }
    }

    my Cro::Service $test = Cro::HTTP::Server.new(
        :host('localhost'), :port(TEST_PORT), application => $app,
        body-serializers => [Cro::HTTP::BodySerializer::StrFallback],
        add-body-serializers => [Cro::HTTP::BodySerializer::JSON]);

    $test.start();
    LEAVE $test.stop();

    given await Cro::HTTP::Client.get("$base/",
                                      content-type => 'text/plain',
                                      body => 'give-me-text') -> $resp {
        subtest {
            is (await $resp.body), 'Hands That Lift the Oceans';
            is $resp.status, 200;
        }, 'Request for one serializer is processed';
    };

    given await Cro::HTTP::Client.get("$base/",
                                      content-type => 'text/plain',
                                      body => 'give-me-json') -> $resp {
        subtest {
            is $resp.status, 200;
        }, 'Request for additional serializer works';
    };
}

done-testing;
