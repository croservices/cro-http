use Cro::TCP;
use Cro::HTTP2::ConnectionState;
use Cro::HTTP2::FrameSerializer;
use Cro::HTTP2::FrameParser;
use Cro::HTTP2::Frame;
use Test;

ok Cro::HTTP2::FrameParser ~~ Cro::Transform,
    'HTTP2 frame parser is a transform';
ok Cro::HTTP2::FrameParser.consumes === Cro::TCP::Message,
    'HTTP2 frame parser consumes TCP messages';
ok Cro::HTTP2::FrameParser.produces === Cro::HTTP2::Frame,
    'HTTP2 frame parser produces HTTP2 frames';

sub test-dying($data, $exception, $code, $desc) {
    my $connection-state = Cro::HTTP2::ConnectionState.new:
        window-size => class :: is Supplier { method emit(|) {} };
    my $parser = Cro::HTTP2::FrameParser.new;
    my $fake-in = Supplier.new;
    my $complete = Promise.new;
    $parser.transformer($fake-in.Supply, :$connection-state).schedule-on($*SCHEDULER).tap: -> $frame {},
    quit => {
        when $exception {
            if .code == $code {
                pass $desc;
                $complete.keep;
            }
        }
        default {
            flunk $desc;
        }
    };
    start {
        # Preface
        $fake-in.emit: Cro::TCP::Message.new(
            data => utf8.new(80,82,73,32,42,32,72,84,84,80,47,50,
                             46,48,13,10,13,10,83,77,13,10,13,10));
        $fake-in.emit(Cro::TCP::Message.new: :$data);
    }
    await Promise.anyof($complete, Promise.in(5));
    unless $complete.status ~~ Kept {
        flunk $desc;
    }
}

sub test-example($buffer, $result, $desc) {
    my $connection-state = Cro::HTTP2::ConnectionState.new:
        window-size => class :: is Supplier { method emit(|) {} };
    my $parser = Cro::HTTP2::FrameParser.new;
    my $serializer = Cro::HTTP2::FrameSerializer.new;
    my $fake-in-p = Supplier.new;
    my $fake-in-s = Supplier.new;
    my $complete = Promise.new;
    $connection-state.settings.Supply.tap: -> $settings {
        if $settings ~~ Bool {
        } else {
            is-deeply $settings, $result, $desc;
            $complete.keep;
        }
    }
    $parser.transformer($fake-in-p.Supply, :$connection-state).schedule-on($*SCHEDULER).tap: -> $frame {
        is-deeply $frame, $result, $desc;
        $serializer.transformer($fake-in-s.Supply, :$connection-state).schedule-on($*SCHEDULER).tap: -> $message {
            is-deeply $buffer, $message.data, $desc ~ ' is serialized back';
            $complete.keep;
        }
        $fake-in-s.emit($frame);
        $fake-in-s.done;
    }
    start {
        # Preface
        $fake-in-p.emit: Cro::TCP::Message.new(
            data => utf8.new(80,82,73,32,42,32,72,84,84,80,47,50,
                             46,48,13,10,13,10,83,77,13,10,13,10));
        $fake-in-p.emit(Cro::TCP::Message.new: data => $buffer);
        $fake-in-p.done;
    }
    await Promise.anyof($complete, Promise.in(5));
    unless $complete.status ~~ Kept {
        flunk $desc;
    }
}

test-dying Buf.new([0x00, 0x00, 0x01, 0x00, 0x08, 0x00, 0x00, 0x00, 0x01,
                    0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
           X::Cro::HTTP2::Error, PROTOCOL_ERROR,
           'DATA Frame length cannot be less than padding length';

test-example Buf.new([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01]),
             Cro::HTTP2::Frame::Data.new(
                 flags => 0, stream-identifier => 1,
                 data => utf8.new),
             'Empty DATA frame';

test-example Buf.new([0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
                      0x61]),
             Cro::HTTP2::Frame::Data.new(
                 flags => 0, stream-identifier => 1,
                 data => 'a'.encode),
             'DATA frame without padding';

test-example Buf.new([0x00, 0x00, 0x07, 0x00, 0x08, 0x00, 0x00, 0x00, 0x01,
                      0x00, 0x68, 0x65, 0x61, 0x64, 0x65, 0x72]),
             Cro::HTTP2::Frame::Data.new(
                 flags => 8, stream-identifier => 1,
                 padding-length => 0, data => 'header'.encode),
             'DATA frame with zero padding';

test-example Buf.new([0x00, 0x00, 0x12, 0x00, 0x08, 0x00, 0x00, 0x00, 0x01,
                      0x0A, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64,
                      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
             Cro::HTTP2::Frame::Data.new(
                 flags => 8, stream-identifier => 1,
                 padding-length => 10, data => 'payload'.encode),
             'DATA frame with padding';

test-dying Buf.new([0x00, 0x00, 0x01, 0x01, 0x08, 0x00, 0x00, 0x00, 0x01,
                    0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
           X::Cro::HTTP2::Error, PROTOCOL_ERROR,
           'HEADERS Frame length cannot be less than padding length';

test-example Buf.new([0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01]),
             Cro::HTTP2::Frame::Headers.new(
                 flags => 0, stream-identifier => 1,
                 headers => Buf.new),
             'Empty HEADERS frame';

test-example Buf.new([0x00, 0x00, 0x06, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01,
                      0x68, 0x65, 0x61, 0x64, 0x65, 0x72]),
             Cro::HTTP2::Frame::Headers.new(
                 flags => 0, stream-identifier => 1,
                 headers => Buf.new('header'.encode)),
             'HEADERS frame without padding';

test-example Buf.new([0x00, 0x00, 0x07, 0x01, 0x08, 0x00, 0x00, 0x00, 0x01,
                      0x00, 0x68, 0x65, 0x61, 0x64, 0x65, 0x72]),
             Cro::HTTP2::Frame::Headers.new(
                 flags => 8, stream-identifier => 1,
                 padding-length => 0, headers => Buf.new('header'.encode)),
             'HEADERS frame with zero padding';

test-dying Buf.new([0x00, 0x00, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00, 0x01,
                    0x00, 0x00, 0x00, 0x01, 0x10]),
           X::Cro::HTTP2::Error, FRAME_SIZE_ERROR,
           'PRIORITY Frame length is always 5 bytes';

test-dying Buf.new([0x00, 0x00, 0x03, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01,
                    0x00, 0x00, 0x00, 0x01]),
           X::Cro::HTTP2::Error, FRAME_SIZE_ERROR,
           'RST_STREAM Frame length is always 4 bytes';

test-dying Buf.new([0x00, 0x00, 0x01, 0x04, 0x01, 0x00, 0x00, 0x00, 0x01,
                    0x00]),
           X::Cro::HTTP2::Error, FRAME_SIZE_ERROR,
           'Ack SETTINGS Frame length is always 0';

test-dying Buf.new([0x00, 0x00, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00, 0x01,
                    0x00, 0x00, 0x01]),
           X::Cro::HTTP2::Error, FRAME_SIZE_ERROR,
           'SETTINGS Frame length is always divisible by 6';

test-dying Buf.new([0x00, 0x00, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x01]),
           X::Cro::HTTP2::Error, FRAME_SIZE_ERROR,
           'SETTINGS Frame length is always divisible by 6';

test-dying Buf.new([0x00, 0x00, 0x03, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x01]),
           X::Cro::HTTP2::Error, FRAME_SIZE_ERROR,
           'WindowIncrement Frame length is always 4';

test-example Buf.new([0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00]),
              Cro::HTTP2::Frame::Settings.new(
                  flags => 0,
                  stream-identifier => 0),
              'SETTINGS frame with zero content is emitted correctly';

done-testing;
