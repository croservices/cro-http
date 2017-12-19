use Cro::TCP;
use Cro::HTTP2::ConnectionState;
use Cro::HTTP2::Frame;
use Cro::Transform;
use Cro;

class Cro::HTTP2::FrameSerializer does Cro::Transform does Cro::ConnectionState[Cro::HTTP2::ConnectionState] {
    has $.client = False;
    has $.enable-push-promises = False;

    method consumes() { Cro::HTTP2::Frame }
    method produces() { Cro::TCP::Message }

    method transformer(Supply:D $in, Cro::HTTP2::ConnectionState :$connection-state!) {
        supply {
            # If it's a client, always start out by sending connection preface
            # and an empty settings frame.
            if $!client {
                emit Cro::TCP::Message.new(data => blob8.new(
                    80,82,73,32,42,32,72,84,84,80,47,50,
                    46,48,13,10,13,10,83,77,13,10,13,10));
                send-message Cro::HTTP2::Frame::Settings.new(
                    flags => 0, stream-identifier => 0,
                    settings => (1 => 4096, 2 => $!enable-push-promises ?? 1 !! 0,
                                 3 => 100, 4 => 65535,
                                 5 => 16384, 6 => 1000)
                );
            }

            my $MAX-FRAME-SIZE = 2 ** 14;
            sub send-message($frame) {
                my $result = self!form-header($frame);
                self!serializer($result, $frame);
                emit Cro::TCP::Message.new(data => $result);
            }

            sub send-splitted($frame) {
                my $is-header = $frame ~~ Cro::HTTP2::Frame::Headers|Cro::HTTP2::Frame::PushPromise;
                my $payload = $is-header ?? $frame.headers !! $frame.data;
                my $flag = $frame.flags == 4 ?? 0 !! 1 if $is-header;
                # Send first piece
                my $first-part = $payload.subbuf(0, $MAX-FRAME-SIZE-9);
                $payload .= subbuf($MAX-FRAME-SIZE-9);
                my %arg = $is-header ?? headers => $first-part !! data => $first-part;
                send-message($frame.clone(
                                    flags => $is-header ?? $flag !! 0,
                                    |%arg));

                while $payload.elems > 0 {
                    my $sent = $payload.elems < $MAX-FRAME-SIZE-9
                             ?? $payload.elems
                             !! $MAX-FRAME-SIZE-9;
                    my $message;
                    %arg = $is-header ?? headers => $payload.subbuf(0, $sent) !! data => $payload.subbuf(0, $sent);
                    %arg<stream-identifier> = $frame.stream-identifier;
                    %arg<flags> = $payload.elems < $MAX-FRAME-SIZE-9 ?? 1 !! 0;
                    if $is-header {
                        $message = Cro::HTTP2::Frame::Continuation.new(|%arg)
                    } else {
                        $message = Cro::HTTP2::Frame::Data.new(|%arg)
                    }
                    send-message($message);
                    $payload .= subbuf($sent);
                }
            }

            enum State <Header Payload>;
            my $buffer;
            my $expecting = Header;

            with $connection-state.ping {
                whenever $connection-state.ping.Supply {
                    my $ack = Cro::HTTP2::Frame::Ping.new(
                        :1flags, :0stream-identifier, payload => .payload
                    );
                    send-message($ack);
                }
            }
            with $connection-state.settings {
                whenever $connection-state.settings.Supply {
                    when Bool { # Preface case
                        # Emit server negotiated settings
                        my $set = Cro::HTTP2::Frame::Settings.new(
                            flags => 0, stream-identifier => 0,
                            settings => (1 => 4096, 2 => 0,
                                         3 => 100, 4 => 65535,
                                         5 => 16384, 6 => 1000)
                        );
                        send-message($set);
                    }
                    default {
                        for .settings -> $pair {
                            if $pair.key == SETTINGS_MAX_FRAME_SIZE {
                                $MAX-FRAME-SIZE = $pair.value;
                            }
                        }
                        my $ack = Cro::HTTP2::Frame::Settings.new(
                            flags => 1, stream-identifier => 0, settings => ()
                        );
                        send-message($ack);
                    }
                }
            }
            with $connection-state.window-size {
                whenever $connection-state.window-size.Supply {
                    send-message($_);
                }
            }

            whenever $in -> Cro::HTTP2::Frame $frame {
                if $frame ~~ Cro::HTTP2::Frame::Headers|Cro::HTTP2::Frame::PushPromise {
                    if $frame.headers.elems + 9 > $MAX-FRAME-SIZE {
                        send-splitted($frame);
                    } else {
                        send-message($frame);
                    }
                } elsif $frame ~~ Cro::HTTP2::Frame::Data {
                    if $frame.data.elems + 9 > $MAX-FRAME-SIZE {
                        send-splitted($frame);
                    } else {
                        send-message($frame);
                    }
                } else {
                    send-message($frame);
                }
            }
        }
    }

    method !serializer(Buf $buf, Cro::HTTP2::Frame $_) {
        when Cro::HTTP2::Frame::Data {
            $buf.append: .padding-length if .padded;
            $buf.append: .data;
            $buf.append: 0 xx .padding-length if .padded;
        }
        when Cro::HTTP2::Frame::Headers {
            $buf.append: .padding-length if .padded;
            my $priority = .priority;
            for 16, 8...0 {
                $buf.append: ((.dependency +> $_) +& 0xFF) if $priority;
            }
            $buf.append: .weight if .priority;
            $buf.append: .headers;
            $buf.append: 0 xx .padding-length if .padded;
        }
        when Cro::HTTP2::Frame::Priority {
            my $num = .dependency;
            my $ex = .exclusive;
            for 24, 16...0 {
                $buf.append: (($num +> $_) +& 0xFF);
                $buf[$buf.elems-1] = $buf[$buf.elems-1] +| 0x80 if $_ == 24 && $ex;
            }
            $buf.append: .weight;
        }
        when Cro::HTTP2::Frame::RstStream {
            my $num = ErrorCode(.error-code) // INTERNAL_ERROR;
            for 24, 16...0 {
                $buf.append: (($num +> $_) +& 0xFF);
            }
        }
        when Cro::HTTP2::Frame::Settings {
            for .settings -> Pair $set {
                # Identifier is two byte long, however values defined per RFC 8540
                # may be defined by a single byte only, so we'll sticking zero byte
                # and settings value here.
                $buf.append: 0; $buf.append: $set.key;
                for 24, 16...0 {
                    $buf.append: (($set.value +> $_) +& 0xFF);
                }
            }
        }
        when Cro::HTTP2::Frame::PushPromise {
            $buf.append: .padding-length if .padded;
            my $num = .promised-sid;
            for 24, 16...0 {
                $buf.append: (($num +> $_) +& 0xFF);
            }
            $buf.append: .headers;
            $buf.append: 0 xx .padding-length if .padded;
        }
        when Cro::HTTP2::Frame::Ping {
            if .payload.elems < 8 {
                my $suffix = Buf.new([0x0 xx (8 - .payload.elems)]);
                $buf.append: .payload; $buf.append: $suffix;
            } elsif .payload.elems == 8 {
                $buf.append: .payload;
            } else {
                die INTERNAL_ERROR;
            }
        }
        when Cro::HTTP2::Frame::GoAway {
            my $num = .last-sid;
            for 24, 16...0 { $buf.append: (($num +> $_) +& 0xFF); }
            $num = ErrorCode(.error-code) // INTERNAL_ERROR;
            for 24, 16...0 { $buf.append: (($num +> $_) +& 0xFF); }
            $buf.append: .debug;
        }
        when Cro::HTTP2::Frame::WindowUpdate {
            my $num = .increment;
            for 24, 16...0 { $buf.append: (($num +> $_) +& 0xFF); }
        }
        when Cro::HTTP2::Frame::Continuation {
            $buf.append: .headers;
        }
    }

    method !form-header(Cro::HTTP2::Frame $_) {
        my $buf = Buf.new;
        my $i = 0;

        # Length
        given $_ {
            when Cro::HTTP2::Frame::Data {
                my $num = .data.elems;
                $num += .padding-length + 1 if .padded;
                for 16, 8...0 { $buf[$i] = ($num +> $_) +& 0xFF; $i++; }
            }
            when Cro::HTTP2::Frame::Headers {
                my $num = .headers.elems;
                $num += .padding-length + 1 if .padded;
                $num += 5 if .priority;
                for 16, 8...0 { $buf[$i] = ($num +> $_) +& 0xFF; $i++; }
            }
            when Cro::HTTP2::Frame::Priority {
                for 16, 8...0 { $buf[$i] = (5 +> $_) +& 0xFF; $i++; }
            }
            when Cro::HTTP2::Frame::RstStream {
                for 16, 8...0 { $buf[$i] = (4 +> $_) +& 0xFF; $i++; }
            }
            when Cro::HTTP2::Frame::Settings {
                my $num = 6 * .settings.elems;
                for 16, 8...0 { $buf[$i] = ($num +> $_) +& 0xFF; $i++; }
            }
            when Cro::HTTP2::Frame::PushPromise {
                my $num = .headers.elems;
                $num += 4; # Promised stream ID
                $num += .padding-length + 1 if .padded;
                for 16, 8...0 { $buf[$i] = ($num +> $_) +& 0xFF; $i++; }
            }
            when Cro::HTTP2::Frame::Ping {
                for 16, 8...0 { $buf[$i] = (8 +> $_) +& 0xFF; $i++; }
            }
            when Cro::HTTP2::Frame::GoAway {
                my $num = .debug.elems + 8;
                for 16, 8...0 { $buf[$i] = ($num +> $_) +& 0xFF; $i++; }
            }
            when Cro::HTTP2::Frame::WindowUpdate {
                for 16, 8...0 { $buf[$i] = (4 +> $_) +& 0xFF; $i++; }
            }
            when Cro::HTTP2::Frame::Continuation {
                my $num = .headers.elems;
                for 16, 8...0 { $buf[$i] = ($num +> $_) +& 0xFF; $i++; }
            }
        }

        # Type
        $buf[$i] = .type;  $i++;
        # Flags
        $buf[$i] = .flags; $i++;
        # Stream ID
        my $num = .stream-identifier;
        die PROTOCOL_ERROR if $num != 0 && $_ ~~ Cro::HTTP2::Frame::Settings;
        die PROTOCOL_ERROR if $num != 0 && $_ ~~ Cro::HTTP2::Frame::Ping;
        die PROTOCOL_ERROR if $num != 0 && $_ ~~ Cro::HTTP2::Frame::GoAway;
        for 24, 16...0 {
            $buf[$i] = ($num +> $_) +& 0xFF; $i++;
        }
        $buf;
    }
}
