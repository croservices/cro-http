use Cro;
use Cro::HTTP::RequestParser;
use Cro::HTTP::ResponseSerializer;
use Cro::SSL;
use Cro::TCP;

my class RequestParserExtension does Cro::Transform {
    has $.body-parsers;
    has $.add-body-parsers;

    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Request }

    method transformer(Supply $pipeline --> Supply) {
        supply {
            whenever $pipeline -> $request {
                if $.body-parsers.defined {
                    $request.body-parser-selector = Cro::HTTP::BodyParserSelector::List.new(parsers => @$.body-parsers);
                }
                if $.add-body-parsers.defined {
                    $request.body-parser-selector = Cro::HTTP::BodyParserSelector::Prepend.new(parsers => @$.add-body-parsers,
                                                                                               next => $request.body-parser-selector);
                }
                emit $request;
            }
        }
    }
}

my class ResponseSerializerExtension does Cro::Transform {
    has $.body-serializers;
    has $.add-body-serializers;

    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::HTTP::Response }

    method transformer(Supply $pipeline --> Supply) {
        supply {
            whenever $pipeline -> $response {
                if $.body-serializers.defined {
                    $response.body-serializer-selector = Cro::HTTP::BodySerializerSelector::List.new(serializers => @$.body-serializers);
                }
                if $.add-body-serializers.defined {
                    $response.body-serializer-selector = Cro::HTTP::BodySerializerSelector::Prepend.new(serializers => @$.add-body-serializers,
                                                                                                        next => $response.body-serializer-selector);
                }
                emit $response;
            }
        }
    }
}

class Cro::HTTP::Server does Cro::Service {
    only method new(Cro::Transform :$application!,
                    :$host, :$port, :%ssl,
                    :$before, :$after,
                    :$add-body-parsers, :$body-parsers,
                    :$add-body-serializers, :$body-serializers) {
        my $listener = %ssl
            ?? Cro::SSL::Listener.new(
                  |(:$host with $host),
                  |(:$port with $port),
                  |%ssl
               )
            !! Cro::TCP::Listener.new(
                  |(:$host with $host),
                  |(:$port with $port)
               );

        my @after = $after ~~ Iterable ?? $after.List !! ($after === Any ?? () !! $after);
        my @before = $before ~~ Iterable ?? $before.List !! ($before === Any ?? () !! $before);

        return Cro.compose(
            service-type => self.WHAT,
            $listener,
            Cro::HTTP::RequestParser.new,
            RequestParserExtension.new(:$add-body-parsers, :$body-parsers),
            |@before,
            $application,
            ResponseSerializerExtension.new(:$add-body-serializers, :$body-serializers),
            |@after,
            Cro::HTTP::ResponseSerializer.new
        )
    }
}
