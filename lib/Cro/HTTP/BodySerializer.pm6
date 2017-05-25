use Cro::HTTP::Message;
use JSON::Fast;

role Cro::HTTP::BodySerializer {
    method is-applicable(Cro::HTTP::Message $message, $body --> Bool) { ... }
    method serialize(Cro::HTTP::Message $message, $body --> Supply) { ... }
    method !set-default-content-type(Cro::HTTP::Message $message, Str $type --> Nil) {
        unless $message.has-header('content-type') {
            $message.append-header('Content-type', $type);
        }
    }
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
        self!set-default-content-type($message, 'application/octet-stream');
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
            with .parameters.first(*.key eq 'charset') {
                $encoding = .value;
            }
        }
        else {
            $message.append-header('Content-type', qq[text/plain; charset="$encoding"]);
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

class Cro::HTTP::BodySeiralizer::WWWFormUrlEncoded does Cro::HTTP::BodySerializer {
    method is-applicable(Cro::HTTP::Message $message, $body --> Bool) {
        with $message.content-type {
            .type eq 'application' && .subtype eq 'x-www-form-urlencoded'
        }
        else {
            False
        }
    }

    proto method serialize(Cro::HTTP::Message $message, $body --> Supply) {*}

    multi method serialize(Cro::HTTP::Message $message, @body --> Supply) {
        my @parts;
        for @body -> $entry {
            if $entry ~~ Pair {
                @parts.push: encode($entry.key) ~ '=' ~ encode($entry.value);
            }
            else {
                die "A list body for application/x-www-form-urlencoded may only contain pairs";
            }
        }
        my $body = @parts.join('&').encode('ascii');
        self!set-content-length($message, $body.bytes);
        supply { emit $body }
    }

    multi method serialize(Cro::HTTP::Message $message, $body --> Supply) {
        die "Do not know how to serialize a $body.^name() as application/x-www-form-urlencoded";
    }

    sub encode($target) {
        $target.subst: :g, /<-[A..Za..z0..9_~.-]>/, -> Str() $encodee {
            $encodee eq ' '
                ?? '+'
                !! $encodee le "\x7F"
                    ?? '%' ~ $encodee.ord.base(16)
                    !! $encodee.encode('utf-8').list.map({ '%' ~ .base(16) }).join
        }
    }
}
