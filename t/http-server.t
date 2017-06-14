use Cro;
use Cro::HTTP::Request;
use Cro::HTTP::Response;
use Cro::HTTP::Server;
use Cro::Transform;
use IO::Socket::Async::SSL;
use Test;

constant TEST_PORT = 31314;

class TestHttpApp does Cro::Transform {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Response }

    method transformer($request-stream) {
        supply {
            whenever $request-stream -> $request {
                given Cro::HTTP::Response.new(:200status) {
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
    constant %ca := { ca-file => 't/certs-and-keys/ca-crt.pem' };
    constant %key-cert := {
        private-key-file => 't/certs-and-keys/server-key.pem',
        certificate-file => 't/certs-and-keys/server-crt.pem'
    };

    my $service = Cro::HTTP::Server.new(
        port => TEST_PORT,
        ssl => %key-cert,
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

{
    use Cro::HTTP::Router;
    use Cro::HTTP::Client;

    my $app = route {
        get -> 'json' {
            request-body 'application/json' => -> $body {
                content 'text/plain', "pair: x is $body<truth>, y is $body<lie>";
            }
        }
    }

    my Cro::Service $test = Cro::HTTP::Server.new(
        :host('localhost'), :port(TEST_PORT), application => $app);#,
        #body-parsers => [Cro::HTTP::BodyParser::JSON.new]);

    $test.start();
    END $test.stop();

    # {
    #     my $base = "http://localhost:{TEST_PORT}";
    #     my %body = :42x, :101y;

    #     given await Cro::HTTP::Client.get("$base/json",
    #                                       content-type => 'application/json',
    #                                       body => %body) -> $resp {
    #         ok $resp ~~ Cro::HTTP::Response, 'Got a response from GET / with JSON packed';
    #         is await($resp.body-text), 'pair: x is 42, y is 101', 'Body text is correct';
    #     };
    # }
}


done-testing;
