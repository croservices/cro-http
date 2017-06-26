use Cro::HTTP::RequestParser;
use Cro::HTTP::ResponseSerializer;
use Cro;

class ParserExtension does Cro::Transform {
    has $.body-parsers;
    has $.add-body-parsers;

    method consumes() { ... }
    method produces() { ... }

    method transformer(Supply $pipeline --> Supply) {
        supply {
            whenever $pipeline -> $message {
                if $.body-parsers.defined {
                    $message.body-parser-selector = Cro::HTTP::BodyParserSelector::List.new(parsers => @$.body-parsers);
                }
                if $.add-body-parsers.defined {
                    $message.body-parser-selector = Cro::HTTP::BodyParserSelector::Prepend.new(parsers => @$.add-body-parsers,
                                                                                               next => $message.body-parser-selector);
                }
                emit $message;
            }
        }
    }
}

class SerializerExtension does Cro::Transform {
    has $.body-serializers;
    has $.add-body-serializers;

    method consumes() { ... }
    method produces() { ... }

    method transformer(Supply $pipeline --> Supply) {
        supply {
            whenever $pipeline -> $message {
                if $.body-serializers.defined {
                    $message.body-serializer-selector = Cro::HTTP::BodySerializerSelector::List.new(serializers => @$.body-serializers);
                }
                if $.add-body-serializers.defined {
                    $message.body-serializer-selector = Cro::HTTP::BodySerializerSelector::Prepend.new(serializers => @$.add-body-serializers,
                                                                                                       next => $message.body-serializer-selector);
                }
                emit $message;
            }
        }
    }
}
