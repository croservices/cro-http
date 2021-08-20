use Cro::HTTP::LogTimelineSchema;
use Cro::HTTP::Request;
use Cro::HTTP::Response;
use Cro::Transform;
use Cro;
use Log::Timeline;

sub wrap-request-logging(Any $middleware, Supply $pipeline, &process --> Supply) {
    if Log::Timeline.has-output {
        my $pre = supply whenever $pipeline -> $request {
            my %annotations := $request.annotations;
            my $task = Cro::HTTP::LogTimeline::RequestMiddleware.start:
                    %annotations<log-timeline>,
                    :middleware($middleware.^name);
            %annotations<log-timeline-middleware> = $task;
            emit $request;
        }
        my $processed = process($pre);
        supply whenever $processed -> $request {
            .end with $request.annotations<log-timeline-middleware>;
            emit $request;
        }
    }
    else {
        process($pipeline)
    }
}

sub wrap-response-logging(Any $middleware, Supply $pipeline, &process --> Supply) {
    if Log::Timeline.has-output {
        my $pre = supply whenever $pipeline -> $response {
            my %annotations := $response.request.annotations;
            my $task = Cro::HTTP::LogTimeline::ResponseMiddleware.start:
                    %annotations<log-timeline>,
                    :middleware($middleware.^name);
            %annotations<log-timeline-middleware> = $task;
            emit $response;
        }
        my $processed = process($pre);
        supply whenever $processed -> $response {
            .end with $response.request.annotations<log-timeline-middleware>;
            emit $response;
        }
    }
    else {
        process($pipeline)
    }
}

role Cro::HTTP::Middleware::Request does Cro::Transform {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Request }

    method transformer(Supply $pipeline --> Supply) {
        supply whenever wrap-request-logging(self, $pipeline, { self.process($_) }) -> $request {
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
        supply whenever wrap-response-logging(self, $pipeline, { self.process($_) }) -> $response {
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
            supply whenever wrap-request-logging($!middleware, $pipeline, { $!middleware.process($_) }) {
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
                whenever $connection-state.early-responses -> $skipped {
                    if $skipped.middleware === $!middleware {
                        emit $skipped.response;
                    }
                }
                whenever $pipeline -> $response {
                    emit $response;
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
            supply whenever wrap-request-logging($!middleware, $pipeline, { $!middleware.process-requests($_) }) {
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
                whenever $connection-state.early-responses -> $skipped {
                    if $skipped.middleware === $!middleware {
                        emit $skipped.response;
                    }
                }
                whenever wrap-response-logging($!middleware, $pipeline, { $!middleware.process-responses($_) }) -> $response {
                    emit $response;
                    LAST $connection-state.early-responses.done;
                }
            }
        }
    }

    method request() { Request.new(middleware => self) }
    method response() { Response.new(middleware => self) }

    method process-requests(Supply $requests --> Supply) { ... }
    method process-responses(Supply $responses --> Supply) { ... }
}
