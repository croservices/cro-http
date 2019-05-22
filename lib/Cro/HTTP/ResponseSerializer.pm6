use Cro::BodySerializerSelector;
use Cro::HTTP::LogTimelineSchema;
use Cro::HTTP::Response;
use Cro::TCP;
use Cro::Transform;

class Cro::HTTP::ResponseSerializer does Cro::Transform {
    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::TCP::Message }

    method transformer(Supply $response-stream) {
        supply {
            whenever $response-stream -> Cro::HTTP::Response $response {
                my $log-timeline-task = $response.request.annotations<log-timeline>;

                # No body expected or allowed for 204 or less than 200.
                my int $status = $response.status;
                if $status == 204 || ($status < 200 && $status != 101) {
                    emit Cro::TCP::Message.new(data => $response.Str.encode('latin-1'));
                    maybe-connection-close();
                    next;
                }

                # Otherwise, obtain body. We must do it before serializing the
                # headers, as this is the point that a content-length header
                # may be added in.
                my $body-byte-stream;
                try {
                    CATCH {
                        when X::Cro::BodySerializerSelector::NoneApplicable {
                            $response.status = 500;
                            $response.remove-header({ True });
                            $response.append-header('Content-length', 0);
                            $body-byte-stream = supply {};
                        }
                    }
                    $body-byte-stream = $response.body-byte-stream;
                }

                if $response.has-header('content-length')
                || $response.has-header('upgrade') {
                    # Has Content-length header, so already all available; no need
                    # for chunked.
                    emit Cro::TCP::Message.new(data => $response.Str.encode('latin-1'));
                    my $resp-body-task = Cro::HTTP::LogTimeline::ResponseBody.start: $log-timeline-task;
                    whenever $body-byte-stream -> $data {
                        emit Cro::TCP::Message.new(:$data);
                        LAST {
                            $resp-body-task.end();
                            maybe-connection-close();
                        }
                    }
                }
                else {
                    # Chunked-encode body as it becomes available.
                    $response.append-header('Transfer-encoding', 'chunked');
                    emit Cro::TCP::Message.new(data => $response.Str.encode('latin-1'));
                    my $resp-body-task = Cro::HTTP::LogTimeline::ResponseBody.start: $log-timeline-task;
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
                            $resp-body-task.end();
                            maybe-connection-close();
                        }
                    }
                }

                # Closes the connection if the sender was using HTTP/1.0 or
                # sent Connection: close.
                sub maybe-connection-close() {
                    $log-timeline-task.end();
                    with $response.request {
                        done if .http-version eq '1.0';
                        with .header('connection') {
                            done if .lc.trim eq 'close';
                        }
                    }
                }
            }
        }
    }
}
