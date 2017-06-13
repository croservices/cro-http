use Cro::HTTP::Server;
use Cro::HTTP::Client;
use Cro::Service;
use Cro::Transform;
use Test;

constant TEST_PORT = 31314;

# Application
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

# Middleware
class StrictTransportSecurity does Cro::Transform {
    has Duration:D $.max-age is required;

    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::HTTP::Response }

    method transformer(Supply $pipeline --> Supply) {
        supply {
            whenever $pipeline -> $response {
                $response.append-header:
                'Strict-Transport-Security',
                "max-age=$!max-age";
                emit $response;
            }
        }
    }
}

{
    my Cro::Service $service = Cro::HTTP::Server.new(
        :host('localhost'), :port(TEST_PORT), application => TestHttpApp,
        after => StrictTransportSecurity.new(max-age => Duration.new(60))
    );
    dies-ok { await IO::Socket::Async.connect('localhost', TEST_PORT) },
        'Server not listening until started';
    lives-ok { $service.start }, 'Can start service';

    my $url = "http://localhost:{TEST_PORT}";

    given await Cro::HTTP::Client.get("$url/") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response from server with middleware inserted';
        is $resp.header('Strict-Transport-Security'), "max-age=60", 'Header was set by middleware';
    }

    END $service.stop();

}

done-testing;
