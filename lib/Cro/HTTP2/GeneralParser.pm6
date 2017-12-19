use Cro::HTTP2::Frame;
use Cro::HTTP::Response;
use Cro::HTTP::Request;
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

role Cro::HTTP2::GeneralParser {
    has $.ping;
    has $.settings;
    has $!pseudo-headers;
    has $.push-promise-supply;

    method transformer(Supply:D $in) {
        supply {
            my $curr-sid = 0;
            my %streams;
            my ($breakable, $break) = (True, $curr-sid);
            my %push-promises;

            with $!push-promise-supply {
                whenever $!push-promise-supply { emit $_ }
            }

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

                    # Process push promises
                    my @promises = %push-promises{.stream-identifier}<>.grep({so $_});
                    if @promises.elems > 0 {
                        if $message ~~ Cro::HTTP::Response {
                            $message.add-push-promise($_) for @promises;
                            $message.close-push-promises;
                        }
                    } else {
                        $message.close-push-promises if $message ~~ Cro::HTTP::Response;
                    }

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
                when Cro::HTTP2::Frame::PushPromise {
                    my @headers = $decoder.decode-headers(Buf.new: .headers);
                    my $pp = Cro::HTTP::PushPromise.new(
                        http2-stream-id => .promised-sid,
                        target => @headers.grep({.name eq ':path'})[0].value,
                        http-version => '2.0',
                        :method<GET>);
                    my @real-headers = @headers.grep({ not .name eq any <:method :scheme :authority :path :status> });
                    for @real-headers { $pp.append-header(.name => .value) }
                    my $promises = %push-promises{.stream-identifier};
                    if $promises ~~ Array {
                        $promises.push: $pp;
                        %push-promises{.stream-identifier} = $promises;
                    } elsif $promises ~~ Cro::HTTP::PushPromise {
                        my @promises = $promises, $pp;
                        %push-promises{.stream-identifier} = @promises;
                    } else {
                        %push-promises{.stream-identifier} = $pp;
                    }
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
