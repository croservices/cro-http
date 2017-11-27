use Cro::HTTP::Request;
use Cro::HTTP::Response;
use Cro::Transform;
use Cro;

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

role Cro::HTTP::Middleware::Pair {
    method request(--> Cro::Transform) { ... }
    method response(--> Cro::Transform) { ... }
}

my class EarlyResponse {
    has $.middleware;
    has $.response;
}

my class SkipPipelineState {
    has Supplier $.early-responses .= new;
}

role Cro::HTTP::Middleware::Conditional does Cro::HTTP::Middleware::Pair {
    my class Request does Cro::Transform does Cro::ConnectionState[SkipPipelineState] {
        has $.middleware;

        method consumes() { Cro::HTTP::Request }
        method produces() { Cro::HTTP::Request }

        method transformer(Supply $pipeline, :$connection-state! --> Supply) {
            supply whenever $!middleware.process($pipeline) {
                when Cro::HTTP::Request {
                    emit $_;
                }
                when Cro::HTTP::Response {
                    $connection-state.early-responses.emit: EarlyResponse.new:
                        :$!middleware, :response($_);
                }
                default {
                    die "Conditional middleware $!middleware.^name() emitted a $_.^name(), " ~
                        "but a Cro::HTTP::Request or Cro::HTTP::Response was required";
                }
            }
        }
    }

    my class Response does Cro::Transform does Cro::ConnectionState[SkipPipelineState] {
        has $.middleware;

        method consumes() { Cro::HTTP::Response }
        method produces() { Cro::HTTP::Response }

        method transformer(Supply $pipeline, :$connection-state! --> Supply) {
            supply {
                whenever $pipeline -> $response {
                    emit $response;
                }
                whenever $connection-state.early-responses -> $skipped {
                    if $skipped.middleware === $!middleware {
                        emit $skipped.response;
                    }
                }
            }
        }
    }

    method request() { Request.new(middleware => self) }
    method response() { Response.new(middleware => self) }

    method process(Supply $requests --> Supply) { ... }
}

role Cro::HTTP::Middleware::RequestResponse does Cro::HTTP::Middleware::Pair {
    my class Request does Cro::Transform does Cro::ConnectionState[SkipPipelineState] {
        has $.middleware;

        method consumes() { Cro::HTTP::Request }
        method produces() { Cro::HTTP::Request }

        method transformer(Supply $pipeline, :$connection-state! --> Supply) {
            supply whenever $!middleware.process-requests($pipeline) {
                when Cro::HTTP::Request {
                    emit $_;
                }
                when Cro::HTTP::Response {
                    $connection-state.early-responses.emit: EarlyResponse.new:
                        :$!middleware, :response($_);
                }
                default {
                    die "Request/Response middleware $!middleware.^name() emitted a $_.^name(), " ~
                        "but a Cro::HTTP::Request or Cro::HTTP::Response was required";
                }
            }
        }
    }

    my class Response does Cro::Transform does Cro::ConnectionState[SkipPipelineState] {
        has $.middleware;

        method consumes() { Cro::HTTP::Response }
        method produces() { Cro::HTTP::Response }

        method transformer(Supply $pipeline, :$connection-state! --> Supply) {
            supply {
                whenever $!middleware.process-responses($pipeline) -> $response {
                    emit $response;
                }
                whenever $connection-state.early-responses -> $skipped {
                    if $skipped.middleware === $!middleware {
                        emit $skipped.response;
                    }
                }
            }
        }
    }

    method request() { Request.new(middleware => self) }
    method response() { Response.new(middleware => self) }

    method process-requests(Supply $requests --> Supply) { ... }
    method process-responses(Supply $responses --> Supply) { ... }
}
