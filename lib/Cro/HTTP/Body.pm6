# HTTP body parsers and serializers can produce/work with any types they wish;
# there is no Cro::HTTP::Body role. This file just collects together various
# objects that represent body types that are built in to Cro.
unit module Cro::HTTP::Body;
use Cro::HTTP::Header;
use Cro::MediaType;
use Cro::HTTP::MultiValue;

class WWWFormUrlEncoded does Associative {
    has @!pairs;
    has $!hashed;

    submethod BUILD(:@pairs) {
        @!pairs := @pairs
    }

    method pairs() {
        Seq.new(@!pairs.iterator)
    }

    method list() {
        self.pairs.list
    }

    method hash() {
        self!hashed
    }

    method AT-KEY(Str() $key) {
        self!hashed.AT-KEY($key)
    }

    method EXISTS-KEY(Str() $key) {
        self!hashed.EXISTS-KEY($key)
    }

    method !hashed() {
        without $!hashed {
            my %hashed-pairs;
            for @!pairs -> $p {
                with %hashed-pairs{$p.key} -> $existing {
                    %hashed-pairs{$p.key} = Cro::HTTP::MultiValue.new(
                        $existing ~~ Cro::HTTP::MultiValue
                            ?? $existing.Slip
                            !! $existing,
                        $p.value
                    );
                }
                else {
                    %hashed-pairs{$p.key} = $p.value;
                }
            }
            $!hashed := %hashed-pairs;
        }
        $!hashed
    }
}

class MultiPartFormData {
    class Part {
        has Cro::HTTP::Header @.headers;
        has Str $.name;
        has Str $.filename;
        has Blob $.body-blob;

        method body-text() {
            (try $!body-blob.decode('utf-8')) // $!body-blob.decode('latin-1')
        }

        method body() {
            self.content-type.type eq 'text'
                ?? self.body-text
                !! self.body-blob
        }

        method content-type() {
            with @!headers.first(*.name.lc eq 'content-type') {
                Cro::MediaType.parse(.value)
            }
            else {
                BEGIN Cro::MediaType.new(type => 'text', subtype-name => 'plain') 
            }
        }
    }

    has Part @.parts;
}
