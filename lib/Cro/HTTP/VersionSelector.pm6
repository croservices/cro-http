use Cro::SSL;
use Cro::HTTP2::ConnectionManager;
use Cro::HTTP::RequestParser;
use Cro::HTTP::ResponseSerializer;
use Cro;

class Cro::HTTP::VersionSelector does Cro::Sink {
    has $!http1;
    has $!http1-supplier;
    has $!http2;
    has $!http2-supplier;

    method consumes() { Cro::SSL::ServerConnection }

    submethod BUILD(:$app) {
        $!http2-supplier = Supplier.new;
        $!http2 = Cro::HTTP2::ConnectionManager.new(:$app).sinker($!http2-supplier.Supply);
        $!http1-supplier = Supplier.new;
        $!http1 = Cro::ConnectionManager.new(
            connection-type => Cro::SSL::ServerConnection,
            components => (
                Cro::HTTP::RequestParser.new,
                $app,
                Cro::HTTP::ResponseSerializer.new
            )
        ).sinker($!http1-supplier.Supply);
        $!http1.tap: quit => { .note };
        $!http2.tap: quit => { .note };
    }

    method sinker(Supply:D $incoming) {
        $incoming.do: -> $_ {
            ($_.alpn-result eq 'h2' ?? $!http2-supplier !! $!http1-supplier).emit($_)
        }
    }
}
