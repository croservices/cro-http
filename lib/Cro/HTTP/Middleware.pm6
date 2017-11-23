use Cro::HTTP::Request;
use Cro::HTTP::Response;
use Cro::Transform;

role Cro::HTTP::Middleware::Request does Cro::Transform {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Request }

    method transformer(Supply $pipeline --> Supply) {
        supply whenever self.process($pipeline) -> $request {
            $request ~~ Cro::HTTP::Request
                ?? emit($request)
                !! die "Request middleware {self.^name} emitted a $request.^name(), " ~
                       "but a Cro::HTTP::Request was required";
        }
    }

    method process(Supply $requests --> Supply) { ... }
}

role Cro::HTTP::Middleware::Response does Cro::Transform {
    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::HTTP::Response }

    method transformer(Supply $pipeline --> Supply) {
        supply whenever self.process($pipeline) -> $response {
            $response ~~ Cro::HTTP::Response
                ?? emit($response)
                !! die "Response middleware {self.^name} emitted a $response.^name(), " ~
                       "but a Cro::HTTP::Response was required";
        }
    }

    method process(Supply $responses --> Supply) { ... }
}
