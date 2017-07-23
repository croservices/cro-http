use Cro::Transform;
use Cro::HTTP2::Frame;
use Cro::HTTP::Request;
use HTTP::HPACK;

my constant $pseudo-headers = <:method :scheme :authority :path :status>;

class Cro::HTTP::RequestParser does Cro::Transform {
    method consumes() { Cro::HTTP2::Frame  }
    method produces() { Cro::HTTP::Request }

    method transformer(Supply:D $in) {
        my enum State <Init Continuation>;
        my $max-stream-id = 1;
        my $decoder = HTTP::HPACK::Decoder.new;
        my $request = Cro::HTTP::Request.new;
        my $state = Init;

        supply {
            whenever $in {
                when .type ~~ Cro::HTTP2::Frame::Data {
                    # TODO
                }
                when .type ~~ Cro::HTTP2::Frame::Headers {
                    my @headers = $decoder.decode-headers(.headers);
                    my @real-headers = @headers.grep({ not .name eq any($pseudo-headers) });
                    $request.method = @headers.grep({ .name eq ':method' })[0].value;
                    $request.target = @headers.grep({ .name eq ':path' })[0].value;
                    $request.http-version = 'http/2';
                    for @real-headers {
                        $request.append-header(.name => .value);
                    }
                    emit $request if .end-headers;
                }
                when .type ~~  Cro::HTTP2::Frame::Priority {
                    die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR) if $state !~~ Init;
                }
                when .type ~~  Cro::HTTP2::Frame::RstStream {
                    die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR) if $state !~~ Init;
                }
                when .type ~~  Cro::HTTP2::Frame::Settings {
                    die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR) if $state !~~ Init;
                }
                when .type ~~  Cro::HTTP2::Frame::Ping {
                    die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR) if $state !~~ Init;
                }
                when .type ~~  Cro::HTTP2::Frame::Goaway {
                    die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR) if $state !~~ Init;
                }
                when .type ~~  Cro::HTTP2::Frame::WindowUpdate {
                    die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR) if $state !~~ Init;
                }
                when .type ~~  Cro::HTTP2::Frame::Continuation {
                    if $state !~~ Continuation {
                        die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR);
                    }
                    my @headers = $decoder.decode-headers(.headers);
                    for @headers {
                        $request.append-header(.name => .value);
                    }
                    emit $request if .end-headers;
                }
            }
        }
    }
}
