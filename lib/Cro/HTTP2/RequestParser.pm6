use Cro::Transform;
use Cro::HTTP2::Frame;
use Cro::HTTP::Request;
use HTTP::HPACK;

my constant $pseudo-headers = <:method :scheme :authority :path :status>;

my enum State <header-init header-c data>;

my class Stream {
    has Int $.sid;
    has State $.state is rw;
    has $.request;
    has Bool $.stream-end is rw;
    has Supplier $.body;
}

class Cro::HTTP2::RequestParser does Cro::Transform {
    method consumes() { Cro::HTTP2::Frame  }
    method produces() { Cro::HTTP::Request }

    method transformer(Supply:D $in) {

        my $curr-sid = 1;
        my $decoder = HTTP::HPACK::Decoder.new;
        my %streams;
        my ($breakable, $break) = (True, $curr-sid);

        supply {
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
                    if .stream-identifier > $curr-sid
                    ||  %streams{.stream-identifier}.state !~~ data
                    || !%streams{.stream-identifier}.request.method
                    || !%streams{.stream-identifier}.request.target {
                        die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR);
                    }

                    my $stream = %streams{.stream-identifier};
                    my $request = $stream.request;
                    $stream.body.emit: .data;
                    if .end-stream {
                        $stream.body.done;
                        emit $request;
                    }
                }
                when Cro::HTTP2::Frame::Headers {
                    if .stream-identifier > $curr-sid {
                        $curr-sid = .stream-identifier;
                        %streams{$curr-sid} = Stream.new(sid => $curr-sid,
                                                         state => header-init,
                                                         request => Cro::HTTP::Request.new(
                                                             http2-stream-id => .stream-identifier
                                                         ),
                                                         stream-end => False,
                                                         body => Supplier::Preserving.new);
                        %streams{$curr-sid}.request.http-version = 'http/2';
                    }
                    my $request = %streams{.stream-identifier}.request;
                    $request.set-body-byte-stream(%streams{.stream-identifier}.body.Supply);

                    my @headers = $decoder.decode-headers(.headers);
                    my @real-headers = @headers.grep({ not .name eq any($pseudo-headers) });

                    for @real-headers {
                        $request.append-header(.name => .value);
                    }

                    unless $request.method {
                        $request.method = @headers.grep({ .name eq ':method' })[0].value;
                    }
                    unless $request.target {
                        $request.target = @headers.grep({ .name eq ':path'   })[0].value;
                    }

                    if .end-headers && .end-stream {
                        # Request is complete without body
                        if $request.method && $request.target {
                            %streams{.stream-identifier}.body.done;
                            emit $request;
                            proceed; # We don't need to change state flags.
                        } else {
                            die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR);
                        }
                    }

                    if .end-headers {
                        %streams{.stream-identifier}.state = data;
                    } else {
                        ($breakable, $break) = (False, .stream-identifier);
                        %streams{.stream-identifier}.stream-end = .end-stream;
                        %streams{.stream-identifier}.body.done if .end-stream;
                        %streams{.stream-identifier}.state = header-c;
                    }
                }
                when Cro::HTTP2::Frame::Priority {
                    my $state = %streams{.stream-identifier}.state;
                    die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR) if $state !~~ header-init|data;
                }
                when Cro::HTTP2::Frame::RstStream {
                    my $state = %streams{.stream-identifier}.state;
                    die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR) if $state !~~ header-init|data;
                }
                when Cro::HTTP2::Frame::Settings {
                    my $state = %streams{.stream-identifier}.state;
                    die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR) if $state !~~ header-init|data;
                }
                when Cro::HTTP2::Frame::Ping {
                    my $state = %streams{.stream-identifier}.state;
                    die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR) if $state !~~ header-init|data;
                }
                when Cro::HTTP2::Frame::Goaway {
                    my $state = %streams{.stream-identifier}.state;
                    die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR) if $state !~~ header-init|data;
                }
                when Cro::HTTP2::Frame::WindowUpdate {
                    my $state = %streams{.stream-identifier}.state;
                    die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR) if $state !~~ header-init|data;
                }
                when Cro::HTTP2::Frame::Continuation {
                    if .stream-identifier > $curr-sid
                    || %streams{.stream-identifier}.state !~~ header-c {
                        die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR)
                    }

                    my $request = %streams{.stream-identifier}.request;
                    my @headers = $decoder.decode-headers(.headers);
                    for @headers {
                        $request.append-header(.name => .value);
                    }

                    # Unbreak lock
                    ($breakable, $break) = (True, 0) if .end-headers;

                    if %streams{.stream-identifier}.stream-end && .end-headers {
                        if $request.target && $request.method {
                            emit $request;
                            proceed;
                        } else {
                            die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR);
                        }
                    }
                    %streams{.stream-identifier}.state = data if .end-headers;
                }
            }
        }
    }
}
