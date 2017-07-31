use Cro::HTTP2::Frame;
use Cro::HTTP::Response;
use Cro::Transform;
use HTTP::HPACK;

class Cro::HTTP2::ResponseSerializer does Cro::Transform {
    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::HTTP2::Frame   }

    method transformer(Supply:D $in) {
        supply {
            sub emit-data($flags, $stream-identifier, $data) {
                emit Cro::HTTP2::Frame::Data.new(
                    :$flags, :$stream-identifier, :$data
                );
            }

            whenever $in -> Cro::HTTP::Response $resp {
                my $body-byte-stream;
                my $encoder = HTTP::HPACK::Encoder.new;
                if $resp.has-body {
                    try {
                        CATCH {
                            when X::Cro::HTTP::BodySerializerSelector::NoneApplicable {
                                $resp.status = 500;
                                $resp.remove-header({ True });
                                $resp.append-header('Content-Length', 0);
                                $body-byte-stream = supply {};
                            }
                        }
                        $body-byte-stream = $resp.body-byte-stream;
                    }
                }
                my @headers = $resp.headers.map({ HTTP::HPACK::Header.new(
                                                        name  => .name.lc,
                                                        value => .value.Str.lc) });
                @headers.unshift: HTTP::HPACK::Header.new(
                    name => ':status',
                    value => $resp.status.Str);
                emit Cro::HTTP2::Frame::Headers.new(
                    flags => $resp.has-body ?? 4 !! 5,
                    stream-identifier => $resp.request.http2-stream-id,
                    headers => $encoder.encode-headers(@headers)
                );

                if $resp.has-body {
                    with $resp.header('Content-Length') {
                        my $counter = $_;
                        whenever $body-byte-stream {
                            $counter -= .elems;
                            die 'Content-Length setting is incorrect: too small' if $counter < 0;
                            emit-data($counter == 0 ?? 1 !! 0,
                                      $resp.request.http2-stream-id, $_);
                            LAST {
                                die 'Content-Length setting is incorrect: too big' if $counter > 0;
                            }
                        }
                    } else {
                        whenever $body-byte-stream {
                            emit-data(0, $resp.request.http2-stream-id, $_);
                            LAST {
                                emit-data(1, $resp.request.http2-stream-id, Buf.new);
                            }
                        }
                    }
                }
            }
        }
    }
}
