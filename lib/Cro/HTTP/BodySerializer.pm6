use Cro::HTTP::Message;

role Cro::HTTP::BodySerializer {
    method is-applicable(Cro::HTTP::Message $message, $body --> Bool) { ... }
    method serialize(Cro::HTTP::Message $message, $body --> Supply) { ... }
}

class Cro::HTTP::BodySerializer::BlobFallback does Cro::HTTP::BodySerializer {
    method is-applicable(Cro::HTTP::Message $message, $body --> Bool) {
        $body ~~ Blob
    }

    method serialize(Cro::HTTP::Message $message, $body --> Supply) {
        if $message.has-header('content-length') {
            $message.remove-header('content-length');
        }
        $message.append-header('Content-length', $body.bytes);
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

        if $message.has-header('content-length') {
            $message.remove-header('content-length');
        }
        $message.append-header('Content-length', $encoded.bytes);

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
