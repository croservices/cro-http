use Cro::HTTP::Request;
use Cro::TCP;
use Cro::Transform;

class Cro::HTTP::RequestSerializer does Cro::Transform {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::TCP::Message }

    method transformer(Supply $request-stream) {
        supply {
            whenever $request-stream -> Cro::HTTP::Request $request {
                if $request.has-body {
                    # Request has a body. We must obtain it before serializing the
                    # headers, as this is the point that a content-length header
                    # may be added in.
                    my $body-byte-stream = $request.body-byte-stream;
                    if $request.has-header('content-length') {
                        # Has Content-length header, so already all available; no need
                        # for chunked.
                        emit Cro::TCP::Message.new(data => $request.Str.encode('latin-1'));
                        whenever $body-byte-stream -> $data {
                            emit Cro::TCP::Message.new(:$data);
                        }
                    }
                    else {
                        # Chunked-encode body as it becomes available.
                        $request.append-header('Transfer-encoding', 'chunked');
                        emit Cro::TCP::Message.new(data => $request.Str.encode('latin-1'));
                        whenever $body-byte-stream -> $data {
                            if $data.elems {
                                my $header = ($data.elems.base(16) ~ "\r\n").encode('ascii');
                                emit Cro::TCP::Message.new(data => $header);
                                emit Cro::TCP::Message.new(:$data);
                                emit Cro::TCP::Message.new(data => Blob.new(13, 10));
                            }
                            LAST {
                                emit Cro::TCP::Message.new(data =>
                                    BEGIN Blob.new(ord("0"), 13, 10, 13, 10)
                                );
                            }
                        }
                    }
                }
                else {
                    emit Cro::TCP::Message.new(data => $request.Str.encode('latin-1'));
                }
            }
        }
    }
}
