use Cro::MediaType;
use Cro::Message;
use Cro::HTTP::Header;

class X::Cro::HTTP::Message::AlreadyHasBody is Exception {
    method message() { "This HTTP message already has a body" }
}

role Cro::HTTP::Message does Cro::Message {
    has Str $.http-version is rw;
    has Cro::HTTP::Header @!headers;
    has Blob $!body-blob;
    has Supply $!body-stream;

    method headers() {
        @!headers.List
    }

    multi method append-header(Cro::HTTP::Header $header --> Nil) {
        @!headers.push($header);
    }

    multi method append-header(Str $header --> Nil) {
        @!headers.push(Cro::HTTP::Header.parse($header));
    }

    multi method append-header(Str $name, Str(Cool) $value --> Nil) {
        @!headers.push(Cro::HTTP::Header.new(:$name, :$value));
    }

    multi method remove-header(Str $name --> Int) {
        my $folded = $name.fc;
        my $removed = 0;
        @!headers .= grep({ not .name.fc eq $folded && ++$removed });
        $removed
    }

    multi method remove-header(&predicate --> Int) {
        my $removed = 0;
        @!headers .= grep({ not predicate($_) && ++$removed });
        $removed
    }

    multi method remove-header(Cro::HTTP::Header $header --> Int) {
        my $removed = 0;
        @!headers .= grep({ not $_ === $header && ++$removed });
        $removed
    }

    method has-header(Str $header-name --> Bool) {
        my $folded = $header-name.fc;
        so @!headers.first(*.name.fc eq $folded)
    }

    method header(Str $header-name) {
        my $folded = $header-name.fc;
        my @matching := @!headers.grep(*.name.fc eq $folded).list;
        @matching == 1
            ?? @matching[0].value
            !! @matching == 0
                ?? Nil
                !! @matching.map(*.value).join(',')
    }

    method header-list(Str $header-name) {
        my $folded = $header-name.fc;
        @!headers.grep(*.name.fc eq $folded).map(*.value).list
    }

    method !headers-str() {
        @!headers.map({ .name ~ ": " ~ .value ~ "\r\n" }).join
    }

    method content-type() {
        with self.header('content-type') {
            Cro::MediaType.parse($_)
        }
        else {
            Nil
        }
    }

    multi method set-body(Blob:D $blob --> Nil) {
        self!ensure-no-body-set();
        $!body-blob = $blob;
    }

    multi method set-body(Supply:D $stream --> Nil) {
        self!ensure-no-body-set();
        $!body-stream = $stream;
    }

    method !ensure-no-body-set() {
        if self!body-set() {
            die X::Cro::HTTP::Message::AlreadyHasBody.new;
        }
    }

    method !body-set() {
        so $!body-blob || $!body-stream
    }

    method has-streaming-body(--> Bool) {
        so $!body-stream
    }

    method body-stream(--> Supply) {
        $!body-stream // supply { emit $!body-blob // Blob.new() }
    }

    method body-blob(--> Promise) {
        Promise(supply {
            my $joined = Buf.new;
            whenever self.body-stream -> $blob {
                $joined.append($blob);
                LAST emit $joined;
            }
        })
    }

    method body-text(--> Promise) {
        self.body-blob.then: -> $blob-promise {
            my $blob = $blob-promise.result;
            my $encoding;
            with self.content-type {
                with .parameters.first(*.key.fc eq 'charset') {
                    $encoding = .value;
                }
            }
            without $encoding {
                # Decoder drops the BOM by itself, it it exists, so just use
                # it for identification here.
                if $blob[0] == 0xEF && $blob[1] == 0xBB && $blob[2] == 0xBF {
                    $encoding = 'utf-8';
                }
                elsif $blob[0] == 0xFF && $blob[1] == 0xFE {
                    $encoding = 'utf-16';
                }
                elsif $blob[0] == 0xFE && $blob[1] == 0xFF {
                    $encoding = 'utf-16';
                }
            }
            $encoding
                ?? $blob.decode($encoding)
                !! (try $blob.decode('utf-8')) // $blob.decode('latin-1')
        }
    }

    method body(--> Promise) {
        self.body-parser-selector.select(self).parse(self)
    }

    method body-parser-selector() { ... }
    method body-serializer-selector() { ... }
}
