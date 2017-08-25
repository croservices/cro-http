use Cro::HTTP2::Frame;
use Cro::HTTP::Response;
use Cro::HTTP::Request;
use HTTP::HPACK;

# HTTP/2 stream
enum State <header-init header-c data>;

class Stream {
    has Int $.sid;
    has State $.state is rw;
    has $.message;
    has Bool $.stream-end is rw;
    has Supplier $.body;
    has Buf $.headers is rw;
}

role Cro::HTTP2::GeneralParser {
    has $.ping;
    has $.settings;
    has $!pseudo-headers;

    method transformer(Supply:D $in) {
        supply {
            my $curr-sid = 0;
            my %streams;
            my ($breakable, $break) = (True, $curr-sid);

            my $decoder = HTTP::HPACK::Decoder.new;
            whenever $in {
                when Any {
                    # Logically, Headers and Continuation are a single frame
                    if !$breakable {
                        if $_ !~~ Cro::HTTP2::Frame::Continuation
                        || $break != .stream-identifier {
                            die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR);
                        }
                    }
                    proceed;
                }
                when Cro::HTTP2::Frame::Data {
                    my $stream = %streams{.stream-identifier};
                    self!check-data($stream, .stream-identifier, $curr-sid);
                    $stream.body.emit: .data;
                    if .end-stream {
                        $stream.body.done;
                        emit $stream.message;
                    }
                }
                when Cro::HTTP2::Frame::Headers {
                    if .stream-identifier > $curr-sid {
                        $curr-sid = .stream-identifier;
                        my $body = Supplier::Preserving.new;
                        %streams{$curr-sid} = Stream.new(
                            sid => $curr-sid,
                            state => header-init,
                            message => self!get-message(.stream-identifier, .connection),
                            stream-end => .end-stream,
                            :$body,
                            headers => Buf.new);
                        %streams{.stream-identifier}.message.set-body-byte-stream($body.Supply);
                    }
                    my $message = %streams{.stream-identifier}.message;

                    if .end-headers {
                        self!set-headers($decoder, $message, .headers);
                        if .end-stream {
                            # Message is complete without body
                            if self!message-full($message) {
                                %streams{.stream-identifier}.body.done;
                                emit $message;
                            } else {
                                die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR);
                            }
                        } else {
                            %streams{.stream-identifier}.state = data;
                        }
                    } else {
                        %streams{.stream-identifier}.headers ~= .headers;
                        # No meaning in lock if we're locked already
                        ($breakable, $break) = (False, .stream-identifier) if $breakable;
                        %streams{.stream-identifier}.body.done if .end-stream;
                        %streams{.stream-identifier}.state = header-c;
                    }
                }
                when Cro::HTTP2::Frame::Priority {
                }
                when Cro::HTTP2::Frame::RstStream {
                }
                when Cro::HTTP2::Frame::Settings {
                    $!settings.emit: $_;
                }
                when Cro::HTTP2::Frame::Ping {
                    $!ping.emit: $_;
                }
                when Cro::HTTP2::Frame::GoAway {
                }
                when Cro::HTTP2::Frame::WindowUpdate {
                }
                when Cro::HTTP2::Frame::Continuation {
                    if .stream-identifier > $curr-sid
                    || %streams{.stream-identifier}.state !~~ header-c {
                        die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR)
                    }
                    my $message = %streams{.stream-identifier}.message;

                    if .end-headers {
                        ($breakable, $break) = (True, 0);
                        my $headers = %streams{.stream-identifier}.headers ~ .headers;
                        self!set-headers($decoder, $message, $headers);
                        %streams{.stream-identifier}.headers = Buf.new;
                        if %streams{.stream-identifier}.stream-end {
                            if self!message-full($message) {
                                emit $message;
                            } else {
                                die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR);
                            }
                        } else {
                            %streams{.stream-identifier}.state = data;
                        }
                    } else {
                        %streams{.stream-identifier}.headers ~= .headers;
                    }
                }
            }
        }
    }

    method !set-headers($decoder, $message, $headers) {
        my @headers = $decoder.decode-headers($headers);
        for @headers {
            last if self!message-full($message);
            if .name eq ':status' && $message ~~ Cro::HTTP::Response {
                $message.status = .value.Int unless $message.status;
            } elsif .name eq ':method' && $message ~~ Cro::HTTP::Request {
                $message.method = .value unless $message.method;
            } elsif .name eq ':path' && $message ~~ Cro::HTTP::Request {
                $message.target = .value unless $message.target;
            }
        }
        my @real-headers = @headers.grep({ not .name eq any (@$!pseudo-headers) });
        for @real-headers { $message.append-header(.name => .value) };
    }
}
