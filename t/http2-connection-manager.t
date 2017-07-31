use Cro;
use Cro::SSL;
use Cro::HTTP2::ConnectionManager;

class HTTPHello does Cro::Transform {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Response }

    method transformer($request-stream) {
        supply {
            whenever $request-stream -> $request {
                given Cro::HTTP::Response.new(:200status, :$request) {
                    .append-header('content-type', 'text/html');
                    .set-body("<strong>Hello from Cro!</strong>");
                    .emit;
                }
            }
        }
    }
}

constant %ca := { ca-file => 't/certs-and-keys/ca-crt.pem' };
constant %key-cert := {
    alpn => 'h2',
    private-key-file => 't/certs-and-keys/server-key.pem',
    certificate-file => 't/certs-and-keys/server-crt.pem'
};

my Cro::Service $http2-service = Cro.compose(
    Cro::SSL::Listener.new(port => 8000, |%key-cert),
    Cro::HTTP2::ConnectionManager.new(app => HTTPHello)
);

$http2-service.start;
note "Started at 8000";
signal(SIGINT).tap: {
    note "Shutting down...";
    $http2-service.stop;
    exit;
}
sleep;
