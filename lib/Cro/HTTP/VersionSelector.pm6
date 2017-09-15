use Cro::HTTP::Internal;
use Cro::HTTP::RequestParser;
use Cro::HTTP::ResponseSerializer;
use Cro::HTTP2::FrameParser;
use Cro::HTTP2::FrameSerializer;
use Cro::HTTP2::RequestParser;
use Cro::HTTP2::ResponseSerializer;
use Cro::TLS;
use Cro;

my class RequestParserExtension is ParserExtension {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Request }
}

my class ResponseSerializerExtension is SerializerExtension {
    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::HTTP::Response }
}

class Cro::HTTP::VersionSelector does Cro::Sink {
    has $!http1;
    has $!http1-supplier;
    has $!http2;
    has $!http2-supplier;

    method consumes() { Cro::TLS::ServerConnection }

    submethod BUILD(:$application,
                    :$before-parse = (), :$before = (),
                    :$after = (), :$after-serialize = (),
                    :$add-body-parsers, :$body-parsers,
                    :$add-body-serializers, :$body-serializers
                   ) {
        $!http2-supplier = Supplier.new;
        $!http2 = Cro::ConnectionManager.new(
            connection-type => Cro::TLS::ServerConnection,
            components => (
                |$before-parse,
                Cro::HTTP2::FrameParser.new,
                Cro::HTTP2::RequestParser.new,
                RequestParserExtension.new(:$add-body-parsers, :$body-parsers),
                |$before,
                $application,
                ResponseSerializerExtension.new(:$add-body-serializers, :$body-serializers),
                |$after,
                Cro::HTTP2::ResponseSerializer.new,
                Cro::HTTP2::FrameSerializer.new,
                |$after-serialize
            )
        ).sinker($!http2-supplier.Supply);
        $!http1-supplier = Supplier.new;
        $!http1 = Cro::ConnectionManager.new(
            connection-type => Cro::TLS::ServerConnection,
            components => (
                |$before-parse,
                Cro::HTTP::RequestParser.new,
                RequestParserExtension.new(:$add-body-parsers, :$body-parsers),
                |$before,
                $application,
                ResponseSerializerExtension.new(:$add-body-serializers, :$body-serializers),
                |$after,
                Cro::HTTP::ResponseSerializer.new,
                |$after-serialize
            )
        ).sinker($!http1-supplier.Supply);
        $!http1.tap: quit => { .note };
        $!http2.tap: quit => { .note };
    }

    method sinker(Supply:D $incoming) {
        $incoming.do: -> $_ {
            (($_.alpn-result // '') eq 'h2'
             ?? $!http2-supplier
             !! $!http1-supplier).emit($_)
        }
    }
}
