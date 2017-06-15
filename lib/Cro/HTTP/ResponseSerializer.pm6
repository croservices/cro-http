use Cro::HTTP::Response;
use Cro::TCP;
use Cro::Transform;

class Cro::HTTP::ResponseSerializer does Cro::Transform {
    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::TCP::Message }

    method transformer(Supply $response-stream) {
        supply {
            whenever $response-stream -> Cro::HTTP::Response $response {
                # No body expected or allowed for 204/200.
                my int $status = $response.status;
                if $status == 204 || $status < 200 {
                    emit Cro::TCP::Message.new(data => $response.Str.encode('latin-1'));
                    done;
                }

                # Otherwise, obtain body. We must do it before serializing the
                # headers, as this is the point that a content-length header
                # may be added in.
                my $body-byte-stream;
                try {
                    CATCH {
                        when X::Cro::HTTP::BodySerializerSelector::NoneApplicable {
                            $response.status = 500;
                            $response.append-header('Content-length', 0);
                            $body-byte-stream = supply {};
                        }
                    }
                    $body-byte-stream = $response.body-byte-stream;
                }

                if $response.has-header('content-length') {
                    # Has Content-length header, so already all available; no need
                    # for chunked.
                    emit Cro::TCP::Message.new(data => $response.Str.encode('latin-1'));
                    whenever $body-byte-stream -> $data {
                        emit Cro::TCP::Message.new(:$data);
                        LAST done;
                    }
                }
                else {
                    # Chunked-encode body as it becomes available.
                    $response.append-header('Transfer-encoding', 'chunked');
                    emit Cro::TCP::Message.new(data => $response.Str.encode('latin-1'));
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
                            done;
                        }
                    }
                }
            }
        }
    }
}
