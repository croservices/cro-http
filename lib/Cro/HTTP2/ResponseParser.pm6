use Cro::HTTP2::Frame;
use Cro::HTTP::Internal;
use Cro::HTTP::Response;
use Cro::Transform;
use HTTP::HPACK;

class Cro::HTTP2::ResponseParser does Cro::Transform {
    method consumes() { Cro::HTTP2::Frame   }
    method produces() { Cro::HTTP::Response }

    method transformer(Supply:D $in) {
        my $curr-sid = 0;
        my %streams;
        my ($breakable, $break) = (True, $curr-sid);

        supply {
            my $decoder = HTTP::HPACK::Decoder.new;

            whenever $in {
                when Any {
                    if !$breakable {
                        if $_ !~~ CrO::HTTP2::Frame::Continuation
                        || $break != .stream-identifier {
                            die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR);
                        }
                    }
                    proceed;
                }
                when Cro::HTTP2::Frame::Data {
                    if .stream-identifier > $curr-sid
                    ||  %streams{.stream-identifier}.state !~~ data {
                        die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR);
                    }

                    my $stream = %streams{.stream-identifier};
                    my $response = $stream.message;
                    $stream.body.emit: .data;
                    if .end-stream {
                        $stream.body.done;
                        emit $response;
                    }
                }
                when Cro::HTTP2::Frame::Headers {
                    if .stream-identifier > $curr-sid {
                        $curr-sid = .stream-identifier;
                        my $body = Supplier::Preserving.new;
                        %streams{$curr-sid} = Stream.new(
                            sid => $curr-sid,
                            state => header-init,
                            message => Cro::HTTP::Response.new,
                            stream-end => .end-stream,
                            :$body,
                            headers => Buf.new);
                        %streams{.stream-identifier}.message.set-body-byte-stream($body.Supply);
                    }
                    my $response = %streams{.stream-identifier}.message;

                    if .end-headers {
                        self!set-headers($decoder, $response, .headers);
                        if .end-stream {
                            # Response is complete without body
                            if $response.status {
                                %streams{.stream-identifier}.body.done;
                                emit $response;
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
                when Cro::HTTP2::Frame::Continuation {
                    if .stream-identifier > $curr-sid
                    || %streams{.stream-identifier}.state !~~ header-c {
                        die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR)
                    }
                    my $response = %streams{.stream-identifier}.message;

                    if .end-headers {
                        ($breakable, $break) = (True, 0);
                        my $headers = %streams{.stream-identifier}.headers ~ .headers;
                        self!set-headers($decoder, $response, $headers);
                        %streams{.stream-identifier}.headers = Buf.new;
                        if %streams{.stream-identifier}.stream-end {
                            if $response.status {
                                emit $response
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
    method !set-headers($decoder, $response, $headers) {
        my @headers = $decoder.decode-headers($headers);
        for @headers {
            last if $response.status;
            if .name eq ':status' {
                $response.status = .value.Int unless $response.status;
            }
        }
        my @real-headers = @headers.grep({ not .name eq any(':status') });
        for @real-headers { $response.append-header(.name => .value) }
    }
}
