use Cro::HTTP2::ConnectionState;
use Cro::HTTP2::Frame;
use Cro::HTTP::Request;
use Cro::HTTP::Response;
use Cro;
use HTTP::HPACK;

# HTTP/2 stream
enum State <header-init header-c data>;

my class Stream {
    has Int $.sid;
    has State $.state is rw;
    has $.message;
    has Bool $.stream-end is rw;
    has Supplier $.body;
    has Buf $.headers is rw;
}

role Cro::HTTP2::GeneralParser does Cro::ConnectionState[Cro::HTTP2::ConnectionState] {
    has $!pseudo-headers;
    has $.enable-push = False;

    method transformer(Supply:D $in, Cro::HTTP2::ConnectionState :$connection-state!) {
        supply {
            my $curr-sid = 0;
            my %streams;
            my ($breakable, $break) = (True, $curr-sid);
            my %push-promises-for-stream;
            my %push-promises-by-promised-id;
            my $decoder = HTTP::HPACK::Decoder.new;

            sub emit-response($sid, $message) {
                with %push-promises-by-promised-id{$sid}:delete {
                    .set-response($message);
                }
                else {
                    emit $message;
                }
            }

            whenever $connection-state.push-promise.Supply { emit $_ }
            whenever $connection-state.settings.Supply {
                when Cro::HTTP2::Frame::Settings {
                    with .settings.grep(*.key == 1) {
                        my $pair = $_.first;
                        $decoder.set-dynamic-table-limit($pair.value) if $pair;
                    }
                    with .settings.grep(*.key == 2) {
                        my $pair = $_.first;
                        $!enable-push = $pair.value != 0 if $pair;
                    }
                }
            }

            whenever $in {
                if !$breakable {
                    if $_ !~~ Cro::HTTP2::Frame::Continuation
                    || $break != .stream-identifier {
                        die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR);
                    }
                }

                when Cro::HTTP2::Frame::Data {
                    my $stream = %streams{.stream-identifier};
                    self!check-data($stream, .stream-identifier, $curr-sid);
                    $stream.body.emit: .data;
                    if .end-stream {
                        $stream.body.done;
                        emit-response(.stream-identifier, $stream.message);
                    }
                }
                when Cro::HTTP2::Frame::Headers {
                    unless %streams{.stream-identifier}:exists {
                        $curr-sid = .stream-identifier;
                        my $body = Supplier::Preserving.new;
                        %streams{$curr-sid} = Stream.new(
                            sid => $curr-sid,
                            state => header-init,
                            message => self!get-message($curr-sid, .connection),
                            stream-end => .end-stream,
                            :$body,
                            headers => Buf.new);
                        %streams{$curr-sid}.message.set-body-byte-stream($body.Supply);
                    }
                    my $message = %streams{.stream-identifier}.message;

                    # Process push promises targetting this response.
                    if $message ~~ Cro::HTTP::Response {
                        if $!enable-push {
                            my @promises = @(
                                %push-promises-for-stream{.stream-identifier}:delete // []
                            );
                            $message.add-push-promise($_) for @promises;
                        }
                        $message.close-push-promises;
                    }

                    if .end-headers {
                        self!set-headers($decoder, $message, .headers);
                        if .end-stream {
                            # Message is complete without body
                            if self!message-full($message) {
                                %streams{.stream-identifier}.body.done;
                                emit-response(.stream-identifier, $message);
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
                    with %push-promises-by-promised-id{.stream-identifier}:delete {
                        .cancel-response();
                    }
                    with %streams{.stream-identifier}:delete {
                        if .message {
                            with .body {
                                .quit('Stream reset');
                            }
                        }
                    } else {
                        die 'Stream reset by the server';
                    }
                    %push-promises-for-stream{.stream-identifier}:delete;
                }
                when Cro::HTTP2::Frame::PushPromise {
                    my @headers = $decoder.decode-headers(Buf.new: .headers);
                    my $pp = Cro::HTTP::PushPromise.new(
                        http2-stream-id => .promised-sid,
                        target => @headers.grep({.name eq ':path'})[0].value,
                        http-version => '2.0',
                        :method<GET>);
                    %push-promises-by-promised-id{.promised-sid} = $pp;
                    my @real-headers = @headers.grep({ not .name eq any <:method :scheme :authority :path :status> });
                    for @real-headers { $pp.append-header(.name => .value) }
                    push %push-promises-for-stream{.stream-identifier}, $pp;
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
                                emit-response(.stream-identifier, $message);
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
