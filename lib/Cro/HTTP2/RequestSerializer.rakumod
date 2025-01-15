use Cro::HTTP2::Frame;
use Cro::HTTP::Request;
use Cro::Transform;
use HTTP::HPACK;

class Cro::HTTP2::RequestSerializer does Cro::Transform {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP2::Frame  }

    method transformer(Supply:D $in) {
        supply {
            whenever $in -> Cro::HTTP::Request $req {
                my $encoder = HTTP::HPACK::Encoder.new;

                my $host;
                my @headers = $req.headers.map: {
                    my $name = .name.lc;
                    my $value = .value.Str;
                    if $name eq 'host' {
                        $host = $value;
                        Empty
                    }
                    else {
                        HTTP::HPACK::Header.new(:$name, :$value)
                    }
                }
                @headers.unshift: HTTP::HPACK::Header.new(
                    name => ':path',
                    value => $req.target);
                @headers.unshift: HTTP::HPACK::Header.new(
                    name => ':scheme',
                    value => 'https'); # TODO We need to handle http case too?
                @headers.unshift: HTTP::HPACK::Header.new(
                    name => ':method',
                    value => $req.method);
                if $host {
                    @headers.unshift: HTTP::HPACK::Header.new(
                            name => ':authority',
                            value => $host);
                }
                emit Cro::HTTP2::Frame::Headers.new(
                    flags => $req.has-body ?? 4 !! 5,
                    stream-identifier => $req.http2-stream-id,
                    headers => $encoder.encode-headers(@headers));

                if $req.has-body {
                    with $req.header('Content-Length') {
                        my $counter = $_;
                        whenever $req.body-byte-stream {
                            $counter -= .elems;
                            die 'Content-Length settings is incorrect: too small' if $counter < 0;
                            emit Cro::HTTP2::Frame::Data.new(
                                flags => $counter == 0 ?? 1 !! 0,
                                stream-identifier => $req.http2-stream-id,
                                data => $_
                            );
                            LAST {
                                die 'Content-Length settings is incorrect: too big' if $counter > 0;
                            }
                        }
                    }
                    else {
                        whenever $req.body-byte-stream {
                            emit Cro::HTTP2::Frame::Data.new(
                                flags => 0,
                                stream-identifier => $req.http2-stream-id,
                                data => $_
                            );
                            LAST {
                                emit Cro::HTTP2::Frame::Data.new(
                                    flags => 1,
                                    stream-identifier => $req.http2-stream-id,
                                    data => Buf.new
                                );
                            }
                        }
                    }
                }
            }
        }
    }
}
