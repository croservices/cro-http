use Cro::TCP;
use Cro::HTTP2::ConnectionState;
use Cro::HTTP2::FrameSerializer;
use Cro::HTTP2::FrameParser;
use Cro::HTTP2::Frame;
use Test;

ok Cro::HTTP2::FrameSerializer ~~ Cro::Transform,
    'HTTP2 frame serializer is a transform';
ok Cro::HTTP2::FrameSerializer.consumes === Cro::HTTP2::Frame,
    'HTTP2 frame serializer consumes HTTP2 frames';
ok Cro::HTTP2::FrameSerializer.produces === Cro::TCP::Message,
    'HTTP2 frame serializer produces TCP messages';

sub test-example($frame, $result, $desc) {
    my $serializer = Cro::HTTP2::FrameSerializer.new;
    my $parser = Cro::HTTP2::FrameParser.new;
    my $fake-in-s = Supplier.new;
    my $fake-in-p = Supplier.new;
    my $complete = Promise.new;

    # Settings/Ping part
    my $settings = Supplier.new;
    my $ping = Supplier.new;
    my $window-size = class :: is Supplier { method emit(|) {} };
    my $once = True;

    my $connection-state = Cro::HTTP2::ConnectionState.new(:$settings, :$ping, :$window-size);
    $serializer.transformer($fake-in-s.Supply, :$connection-state).schedule-on($*SCHEDULER).tap: -> $message {
        if $once {
            $once = False;
            ok $message.data eq $result, $desc;
            $parser.transformer($fake-in-p.Supply, :$connection-state).schedule-on($*SCHEDULER).tap: -> $newframe {
                is-deeply $newframe, $frame, $desc ~ ' is parsed back';
                $complete.keep;
            }
            # Preface
            if $frame ~~ Cro::HTTP2::Frame::Settings|Cro::HTTP2::Frame::Ping {
                $settings.Supply.tap: -> $_ {
                    if $_ ~~ Cro::HTTP2::Frame {
                        is-deeply $_, $frame, 'Settings frame is successful';
                        $complete.keep
                    }
                };
                $ping.Supply.tap: -> $_ {
                    is-deeply $_, $frame, 'Ping frame is successful';
                    $complete.keep
                };
            }
            $fake-in-p.emit: Cro::TCP::Message.new(
                data => utf8.new(80,82,73,32,42,32,72,84,84,80,47,50,
                                 46,48,13,10,13,10,83,77,13,10,13,10));
            $fake-in-p.emit($message);
            $fake-in-p.done;
        }
    }
    start {
        $fake-in-s.emit($frame);
        $fake-in-s.done;
    }
    await Promise.anyof($complete, Promise.in(5));
    if $complete.status != Kept {
        flunk "$desc is not parsed back!";
    }
}

sub test-multi($frame, @result, $size, $max-frame-size, $desc) {
    my $fake-in = Supplier.new;
    my $serializer = Cro::HTTP2::FrameSerializer.new;
    my $connection-state = Cro::HTTP2::ConnectionState.new:
        window-size => class :: is Supplier { method emit(|) {} };
    my $complete = Promise.new;
    my $count = 0;
    $serializer.transformer($fake-in.Supply, :$connection-state).tap: -> $message {
        ok $message.data eq @result[$count];
        $count++;
        $complete.keep if $size == $count;
    },
    quit => {
        note $_;
        $complete.break;
    }
    start {
        $connection-state.settings.emit(Cro::HTTP2::Frame::Settings.new(settings => [5 => $max-frame-size]));
        $fake-in.emit($frame);
        $fake-in.done;
    }
    await Promise.anyof($complete, Promise.in(5));
    if $complete.status ~~ Kept {
        pass $desc;
    } else {
        flunk $desc;
    }
}

test-example Cro::HTTP2::Frame::Data.new(flags => 1, stream-identifier => 1,
                                         data => 'testdata'.encode),
    Buf.new([0x00, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00,
             0x01, 0x74, 0x65, 0x73, 0x74, 0x64, 0x61, 0x74, 0x61]),
    'Simple data frame';

test-example Cro::HTTP2::Frame::Data.new(flags => 9, stream-identifier => 1,
                                         data => 'testdata'.encode,
                                         padding-length => 10),
    Buf.new([0x00, 0x00, 0x13, 0x00, 0x09, 0x00, 0x00, 0x00, 0x01,
             0x0A, 0x74, 0x65, 0x73, 0x74, 0x64, 0x61, 0x74, 0x61,
             0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]), # padding
    'Simple data frame with padding';

test-example Cro::HTTP2::Frame::Headers.new(flags => 1, stream-identifier => 1,
                                            headers => Buf.new('testdata'.encode)),
    Buf.new([0x00, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x00,
             0x01, 0x74, 0x65, 0x73, 0x74, 0x64, 0x61, 0x74, 0x61]),
    'Simple headers frame';

test-example Cro::HTTP2::Frame::Headers.new(flags => 9, stream-identifier => 1,
                                            headers => Buf.new('testdata'.encode),
                                            padding-length => 10),
    Buf.new([0x00, 0x00, 0x13, 0x01, 0x09, 0x00, 0x00, 0x00, 0x01,
             0x0A, 0x74, 0x65, 0x73, 0x74, 0x64, 0x61, 0x74, 0x61,
             0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]), # padding
    'Simple headers frame with padding';

test-example Cro::HTTP2::Frame::Priority.new(flags => 0, stream-identifier => 1,
                                             dependency => 4, weight => 64, exclusive => True),
    Buf.new([0x00, 0x00, 0x05, 0x02, 0x00, 0x00, 0x00, 0x00, 0x01,
             0x80, 0x00, 0x00, 0x04, 0x40]),
    'Simple priority frame';

test-example Cro::HTTP2::Frame::RstStream.new(flags => 0, stream-identifier => 1,
                                              error-code => INTERNAL_ERROR),
    Buf.new([0x00, 0x00, 0x04, 0x03, 0x00, 0x00, 0x00,
             0x00, 0x01, 0x00, 0x00, 0x00, 0x02]),
    'Simple RstStream frame';

test-example Cro::HTTP2::Frame::RstStream.new(flags => 0, stream-identifier => 1,
                                              error-code => 35),
    Buf.new([0x00, 0x00, 0x04, 0x03, 0x00, 0x00, 0x00,
             0x00, 0x01, 0x00, 0x00, 0x00, 0x02]),
    'RstStream frame with a custom error treats it as INTERNAL_ERROR';

my @settings = SETTINGS_HEADER_TABLE_SIZE.value => 4096,
               SETTINGS_ENABLE_PUSH.value => 0,
               SETTINGS_MAX_CONCURRENT_STREAMS.value => 100,
               SETTINGS_INITIAL_WINDOW_SIZE.value => 65535,
               SETTINGS_MAX_FRAME_SIZE.value => 16384,
               SETTINGS_MAX_HEADER_LIST_SIZE.value => 65535;
test-example Cro::HTTP2::Frame::Settings.new(flags => 0, stream-identifier => 0,
                                             :@settings),
    Buf.new([0x00, 0x00, 0x24, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00,
             0x00, 0x01, 0x00, 0x00, 0x10, 0x00,
             0x00, 0x02, 0x00, 0x00, 0x00, 0x00,
             0x00, 0x03, 0x00, 0x00, 0x00, 0x64,
             0x00, 0x04, 0x00, 0x00, 0xFF, 0xFF,
             0x00, 0x05, 0x00, 0x00, 0x40, 0x00,
             0x00, 0x06, 0x00, 0x00, 0xFF, 0xFF]),
    'Simple Settings frame';

test-example Cro::HTTP2::Frame::PushPromise.new(flags => 4, stream-identifier => 1,
                                                promised-sid => 4, headers => 'hello world'.encode),
    Buf.new([0x00, 0x00, 0x0F, 0x05, 0x04, 0x00, 0x00, 0x00, 0x01,
             0x00, 0x00, 0x00, 0x04,
             0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0x77, 0x6F, 0x72, 0x6C, 0x64]),
    'Simple PushPromise frame';

test-example Cro::HTTP2::Frame::PushPromise.new(flags => 8, stream-identifier => 1,
                                                padding-length => 1,
                                                promised-sid => 4, headers => 'hello world'.encode),
    Buf.new([0x00, 0x00, 0x11, 0x05, 0x08, 0x00, 0x00, 0x00, 0x01,
             0x01, 0x00, 0x00, 0x00, 0x04,
             0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0x77, 0x6F, 0x72, 0x6C, 0x64, 0x00]),
    'PushPromise frame with padding';

test-example Cro::HTTP2::Frame::Ping.new(flags => 1, stream-identifier => 0,
                                         payload => Blob.new([0x1, 0x2])),
    Buf.new([0x00, 0x00, 0x08, 0x06, 0x01, 0x00, 0x00, 0x00, 0x00,
             0x01, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
    'Simple Ping frame';

dies-ok {
    test-example Cro::HTTP2::Ping::Settings.new(flags => 1,
                                                payload => Blob.new(0x0 xx 10));
}, 'Ping payload cannot be more than 8 bytes';

test-example Cro::HTTP2::Frame::GoAway.new(flags => 0, stream-identifier => 0,
                                           last-sid => 64, error-code => REFUSED_STREAM,
                                           debug => 'hello'.encode),
    Buf.new([0x00, 0x00, 0x0D, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00,
             0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x07, 0x68, 0x65, 0x6c, 0x6c, 0x6f]),
    'Simple GoAway frame';

test-example Cro::HTTP2::Frame::GoAway.new(flags => 0, stream-identifier => 0,
                                           last-sid => 64, error-code => 50,
                                           debug => 'hello'.encode),
    Buf.new([0x00, 0x00, 0x0D, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00,
             0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x02, 0x68, 0x65, 0x6c, 0x6c, 0x6f]),
    'GoAway frame with a custom error treats it as INTERNAL_ERROR';

test-example Cro::HTTP2::Frame::WindowUpdate.new(flags => 0, stream-identifier => 0,
                                                 increment => 512),
    Buf.new([0x00, 0x00, 0x04, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
             0x00, 0x00, 0x02, 0x00]),
    'Simple WindowUpdate frame';

test-example Cro::HTTP2::Frame::Continuation.new(flags => 4, stream-identifier => 1,
                                                 headers => 'hello world'.encode),
    Buf.new([0x00, 0x00, 0x0B, 0x09, 0x04, 0x00, 0x00, 0x00, 0x01,
             0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x77, 0x6f, 0x72, 0x6c, 0x64]),
    'Simple Continuation frame';

# Too long header
my $headers = Buf.new(<0 1>.pick xx 15);
test-multi Cro::HTTP2::Frame::Headers.new(flags => 5, stream-identifier => 1, :$headers),
           [Buf.new([0x00, 0x00, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00]),
            Buf.new([0x00, 0x00, 0x0b, 0x01, 0x01, 0x00, 0x00, 0x00, 0x01])
            ~ $headers.subbuf(0, 11),
            Buf.new([0x00, 0x00, 0x04, 0x09, 0x01, 0x00, 0x00, 0x00, 0x01])
                    ~ $headers.subbuf(11)],
           3, 20, 'Too long Headers frame is splitted';

my $data = Buf.new(<0 1>.pick xx 15);
test-multi Cro::HTTP2::Frame::Data.new(flags => 1, stream-identifier => 1, :$data),
           [Buf.new([0x00, 0x00, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00]),
            Buf.new([0x00, 0x00, 0x0b, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
                    ~ $data.subbuf(0, 11),
            Buf.new([0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01])
                    ~ $data.subbuf(11)],
           3, 20, 'Too long Data frame is splitted';

done-testing;
