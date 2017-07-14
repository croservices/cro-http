use Cro;
use Cro::HTTP::Internal;
use Cro::HTTP::RequestParser;
use Cro::HTTP::ResponseSerializer;
use Cro::SSL;
use Cro::TCP;

my class RequestParserExtension is ParserExtension {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Request }
}

my class ResponseSerializerExtension is SerializerExtension {
    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::HTTP::Response }
}

class Cro::HTTP::Server does Cro::Service {
    method !convert-middleware($middle) {
        $middle ~~ Iterable ?? $middle.List !! ($middle === Any ?? () !! $middle)
    }

    only method new(Cro::Transform :$application!,
                    :$host, :$port, :%ssl,
                    :$before-parse, :$before,
                    :$after, :$after-serialize,
                    :$add-body-parsers, :$body-parsers,
                    :$add-body-serializers, :$body-serializers,
                    :$label = "HTTP($port)") {
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

        my @before = self!convert-middleware($before);
        my @after = self!convert-middleware($after);
        my @before-parse = self!convert-middleware($before-parse);
        my @after-serialize = self!convert-middleware($after-serialize);

        return Cro.compose(
            service-type => self.WHAT,
            :$label,
            $listener,
            |@before-parse,
            Cro::HTTP::RequestParser.new,
            RequestParserExtension.new(:$add-body-parsers, :$body-parsers),
            |@before,
            $application,
            ResponseSerializerExtension.new(:$add-body-serializers, :$body-serializers),
            |@after,
            Cro::HTTP::ResponseSerializer.new,
            |@after-serialize
        )
    }
}
