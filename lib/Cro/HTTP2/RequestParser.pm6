use Cro::HTTP2::Frame;
use Cro::HTTP::Internal;
use Cro::HTTP::Request;
use Cro::Transform;
use HTTP::HPACK;

my constant $pseudo-headers = <:method :scheme :authority :path :status>;

class Cro::HTTP2::RequestParser does Cro::Transform {
    has $.ping;
    has $.settings;

    method consumes() { Cro::HTTP2::Frame  }
    method produces() { Cro::HTTP::Request }

    method transformer(Supply:D $in) {

        my $curr-sid = 0;
        my %streams;
        my ($breakable, $break) = (True, $curr-sid);

        supply {
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
                    if .stream-identifier > $curr-sid
                    ||  $stream.state !~~ data
                    || !$stream.message.method
                    || !$stream.message.target {
                        die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR);
                    }

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
                            message => Cro::HTTP::Request.new(
                                http2-stream-id => .stream-identifier,
                                http-version => 'http/2'
                            ),
                            stream-end => .end-stream,
                            :$body,
                            headers => Buf.new);
                        %streams{.stream-identifier}.message.set-body-byte-stream($body.Supply);
                    }
                    my $request = %streams{.stream-identifier}.message;

                    if .end-headers {
                        self!set-headers($decoder, $request, .headers);
                        if .end-stream {
                            # Request is complete without body
                            if $request.method && $request.target {
                                %streams{.stream-identifier}.body.done;
                                emit $request;
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
                    my $request = %streams{.stream-identifier}.message;

                    if .end-headers {
                        ($breakable, $break) = (True, 0);
                        my $headers = %streams{.stream-identifier}.headers ~ .headers;
                        self!set-headers($decoder, $request, $headers);
                        %streams{.stream-identifier}.headers = Buf.new;
                        if %streams{.stream-identifier}.stream-end {
                            if $request.target && $request.method {
                                emit $request;
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

    method !set-headers($decoder, $request, $headers) {
        my @headers = $decoder.decode-headers($headers);
        for @headers {
            last if $request.method && $request.target;
            if .name eq ':method' {
                $request.method = .value unless $request.method;
            } elsif .name eq ':path' {
                $request.target = .value unless $request.target;
            }
        }
        my @real-headers = @headers.grep({ not .name eq any($pseudo-headers) });
        for @real-headers { $request.append-header(.name => .value) }
    }
}
