use Cro::HTTP2::FrameParser;
use Cro::HTTP2::FrameSerializer;
use Cro::HTTP2::RequestParser;
use Cro::HTTP2::ResponseSerializer;
use Cro::HTTP::Internal;
use Cro::SSL;
use Cro;

my class RequestParserExtension is ParserExtension {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Request }
}

my class ResponseSerializerExtension is SerializerExtension {
    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::HTTP::Response }
}

class Cro::HTTP2::ConnectionManager does Cro::Sink {
    has Cro::Transform $!transformer;

    method consumes() { Cro::SSL::ServerConnection }

    submethod BUILD(:$application,
                    :$add-body-parsers, :$body-parsers,
                    :$add-body-serializers, :$body-serializers,
                    :$before-parse = (), :$before = (),
                    :$after = (), :$after-serializer = ()) {
        my @components = (
            |$before-parse,
            Cro::HTTP2::FrameParser,
            Cro::HTTP2::RequestParser.new,
            RequestParserExtension.new(:$add-body-parsers, :$body-parsers),
            |$before,
            $application,
            ResponseSerializerExtension.new(:$add-body-serializers, :$body-serializers),
            |$after,
            Cro::HTTP2::ResponseSerializer.new,
            Cro::HTTP2::FrameSerializer,
            |$after-serializer
        );
        $!transformer = Cro.compose(service-type => self.WHAT, @components, :for-connection);
    }

    method sinker(Supply:D $incoming) {
        $incoming.do: -> $connection {
            my $messages = $connection.incoming;
            my $sink = $connection.replier.sinker($!transformer.transformer($messages));
            $sink.tap: quit => { .note };
        }
    }
}
