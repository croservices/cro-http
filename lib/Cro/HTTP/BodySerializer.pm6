use Cro::HTTP::Message;
use JSON::Fast;

role Cro::HTTP::BodySerializer {
    method is-applicable(Cro::HTTP::Message $message, $body --> Bool) { ... }
    method serialize(Cro::HTTP::Message $message, $body --> Supply) { ... }
    method !set-content-length(Cro::HTTP::Message $message, Int $length --> Nil) {
        if $message.has-header('content-length') {
            $message.remove-header('content-length');
        }
        $message.append-header('Content-length', $length);
    }
}

class Cro::HTTP::BodySerializer::BlobFallback does Cro::HTTP::BodySerializer {
    method is-applicable(Cro::HTTP::Message $message, $body --> Bool) {
        $body ~~ Blob
    }

    method serialize(Cro::HTTP::Message $message, $body --> Supply) {
        self!set-content-length($message, $body.bytes);
        supply { emit $body }
    }
}

class Cro::HTTP::BodySerializer::StrFallback does Cro::HTTP::BodySerializer {
    method is-applicable(Cro::HTTP::Message $message, $body --> Bool) {
        $body ~~ Str
    }

    method serialize(Cro::HTTP::Message $message, $body --> Supply) {
        my $encoding = 'utf-8';
        with $message.content-type {
            with .parameters.first(*.name eq 'charset') {
                $encoding = .value;
            }
        }
        my $encoded = $body.encode($encoding);
        self!set-content-length($message, $encoded.bytes);
        supply { emit $encoded }
    }
}

class Cro::HTTP::BodySerializer::SupplyFallback does Cro::HTTP::BodySerializer {
    method is-applicable(Cro::HTTP::Message $message, $body --> Bool) {
        $body ~~ Supply
    }

    method serialize(Cro::HTTP::Message $message, $body --> Supply) {
        supply {
            whenever $body -> $chunk {
                unless $chunk ~~ Blob {
                    die "SupplyFallback body serializer can only handle Supply that emits Blobs";
                }
                emit $chunk;
            }
        }
    }
}

class Cro::HTTP::BodySerializer::JSON does Cro::HTTP::BodySerializer {
    method is-applicable(Cro::HTTP::Message $message, $body --> Bool) {
        with $message.content-type {
            (.type eq 'application' && .subtype eq 'json' || .suffix eq 'json') &&
                ($body ~~ Map || $body ~~ List)
        }
        else {
            False
        }
    }

    method serialize(Cro::HTTP::Message $message, $body --> Supply) {
        my $json = to-json($body, :!pretty).encode('utf-8');
        self!set-content-length($message, $json.bytes);
        supply { emit $json }
    }
}
