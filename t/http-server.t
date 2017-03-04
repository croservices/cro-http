use Crow::HTTP::Request;
use Crow::HTTP::Response;
use Crow::HTTP::Server;
use Crow::Transform;
use Test;

constant TEST_PORT = 31314;

class TestHttpApp does Crow::Transform {
    method consumes() { Crow::HTTP::Request }
    method produces() { Crow::HTTP::Response }

    method transformer($request-stream) {
        supply {
            whenever $request-stream -> $request {
                given Crow::HTTP::Response.new(:200status) {
                    .append-header('Content-type', 'text/html');
                    .set-body("<strong>Hello from Crow!</strong>".encode('ascii'));
                    .emit;
                }
            }
        }
    }
}

{
    my $service = Crow::HTTP::Server.new(
        port => TEST_PORT,
        application => TestHttpApp
    );
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
    like $response, /"<strong>Hello from Crow!</strong>"/,
        'Response contains expected body';

    lives-ok { $service.stop }, 'Can stop service';
    dies-ok { await IO::Socket::Async.connect('localhost', TEST_PORT) },
        'Server not listening after stopped';
}

done-testing;
