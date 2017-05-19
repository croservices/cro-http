use Cro::HTTP::Response;
use Cro::TCP;
use Cro::Transform;

class Cro::HTTP::ResponseSerializer does Cro::Transform {
    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::TCP::Message }

    method transformer(Supply $response-stream) {
        supply {
            whenever $response-stream -> Cro::HTTP::Response $response {
                my int $status = $response.status;
                if $status == 204 || $status < 200 {
                    # No body expected or allowed.
                    emit Cro::TCP::Message.new(data => $response.Str.encode('latin-1'));
                    done;
                }
                elsif $response.has-streaming-body {
                    # Emit header.
                    $response.append-header('Transfer-encoding', 'chunked');
                    emit Cro::TCP::Message.new(data => $response.Str.encode('latin-1'));

                    # Chunked-encode body as it becomes available.
                    whenever $response.body-stream() -> $data {
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
                else {
                    # Body already fully available; use Content-length.
                    my @body-messages;
                    my $length = 0;
                    whenever $response.body-stream() -> $data {
                        @body-messages.push(Cro::TCP::Message.new(:$data));
                        $length += $data.elems;
                        LAST {
                            $response.append-header('Content-length', $length.Str);
                            emit Cro::TCP::Message.new(data => $response.Str.encode('latin-1'));
                            .emit for @body-messages;
                            done;
                        }
                    }
                }
            }
        }
    }
}
