use Cro::HTTP::Request;
use Cro::TCP;
use Cro::Transform;

class Cro::HTTP::RequestSerializer does Cro::Transform {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::TCP::Message }

    method transformer(Supply $response-stream) {
        supply {
            whenever $response-stream -> Cro::HTTP::Request $request {
                # TODO support request body
                emit Cro::TCP::Message.new(data => $request.Str.encode('latin-1'));
            }
        }
    }
}
