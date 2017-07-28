use Cro;
use Cro::SSL;
use Cro::HTTP2::FrameParser;
use Cro::HTTP2::FrameSerializer;
use Cro::HTTP2::RequestParser;
use Cro::HTTP2::ResponseSerializer;

class Cro::HTTP2::ConnectionManager does Cro::Sink {
    has Cro::Transform $!transformer;

    method consumes() { Cro::SSL::ServerConnection }

    submethod BUILD(:$app) {
        my @components = (
            Cro::HTTP2::RequestParser.new,
            $app,
            Cro::HTTP2::ResponseSerializer.new
        );
        $!transformer = Cro.compose(service-type => self.WHAT, @components);
    }

    method sinker(Supply:D $incoming) {
        $incoming.do: -> $connection {
            my $messages = $connection.incoming;
            my $settings = Supplier::Preserving.new;
            my $ping = Supplier::Preserving.new;
            my $fp = Cro::HTTP2::FrameParser.new(:$settings, :$ping);
            my $fs = Cro::HTTP2::FrameSerializer.new(settings => $settings.Supply,
                                                     ping => $ping.Supply);
            my $to-sink = Cro.compose($fp, $!transformer, $fs).transformer($messages);
            my $sink = $connection.replier.sinker($to-sink);
            $sink.tap: quit => { .note };
        }
    }
}
