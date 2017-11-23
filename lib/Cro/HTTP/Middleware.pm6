use Cro::HTTP::Request;
use Cro::HTTP::Response;
use Cro::Transform;

role Cro::HTTP::Middleware::Request does Cro::Transform {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Request }

    method transformer(Supply $pipeline --> Supply) {
        self.process($pipeline)
    }

    method process(Supply $requests --> Supply) { ... }
}

role Cro::HTTP::Middleware::Response does Cro::Transform {
    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::HTTP::Response }

    method transformer(Supply $pipeline --> Supply) {
        self.process($pipeline)
    }

    method process(Supply $responses --> Supply) { ... }
}
