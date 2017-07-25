use Cro::HTTP2::Frame;
use Cro::HTTP::Response;
use Cro::Transform;
use HTTP::HPACK;

class Cro::HTTP2::ResponseSerializer does Cro::Transform {
    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::HTTP2::Frame   }

    method transformer(Supply:D $in) {
        my $encoder = HTTP::HPACK::Encoder.new;
        supply {
            whenever $in -> Cro::HTTP::Response $resp {
                my @headers = $resp.headers.map({ HTTP::HPACK::Header.new(
                                                        name  => .name,
                                                        value => .value.Str) });
                @headers.push: HTTP::HPACK::Header.new(
                    name => ':status',
                    value => $resp.status.Str);
                emit Cro::HTTP2::Frame::Headers.new(
                    flags => $resp.has-body ?? 4 !! 5,
                    stream-identifier => $resp.request.http2-stream-id,
                    headers => $encoder.encode-headers(@headers)
                );

                if $resp.has-body {
                    my $body-byte-stream;
                    try {
                        CATCH {
                            when X::Cro::HTTP::BodySerializerSelector::NoneApplicable {
                                $resp.status = 500;
                                $resp.remove-header({ True });
                                $resp.append-header('Content-length', 0);
                                $body-byte-stream = supply {};
                            }
                        }
                        $body-byte-stream = $resp.body-byte-stream;
                    }
                    my $counter = $resp.header('Content-length');
                    whenever $body-byte-stream {
                        $counter -= .elems;
                        emit Cro::HTTP2::Frame::Data.new(
                            flags => $counter == 0 ?? 1 !! 0,
                            stream-identifier => $resp.request.http2-stream-id,
                            data => $_
                        );
                    }
                }
            }
        }
    }
}
