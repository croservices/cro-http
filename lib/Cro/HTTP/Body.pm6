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

    method keys() {
        self.pairs.map(*.key)
    }

    method values() {
        self.pairs.map(*.value)
    }

    method list() {
        self.pairs.list
    }

    method gist() {
        self.^name ~ '(' ~ self.list.map({.key ~ '=｢' ~ .value ~ '｣'}).join(',') ~ ')'
    }

    method perl() {
        self.^name ~ '.new(:pairs[' ~ self.list.perl ~ '])'
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

    method Capture() {
        Capture.new(hash => self!hashed)
    }
}

class MultiPartFormData does Associative {
    class Part does Stringy {
        has Cro::HTTP::Header @.headers;
        has Str $.name;
        has Str $.filename;
        has Blob $.body-blob;

        multi method Stringy(::?CLASS:D:) { self.Str }
        multi method Str(::?CLASS:D:) { self.body-text }

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
    has $!hashed;

    method hash() { self!hashed }

    method AT-KEY(Str() $key) {
        self!hashed.AT-KEY($key)
    }

    method EXISTS-KEY(Str() $key) {
        self!hashed.EXISTS-KEY($key);
    }

    method !hashed() {
        without $!hashed {
            my %hashed-pairs;
            for @!parts -> $p {
                with %hashed-pairs{$p.name} -> $existing {
                    %hashed-pairs{$p.name} = Cro::HTTP::MultiValue.new(
                        $existing ~~ Cro::HTTP::MultiValue
                            ?? $existing.Slip
                            !! $existing,
                        $p
                    )
                }
                else {
                    %hashed-pairs{$p.name} = $p;
                }
            }
            $!hashed = %hashed-pairs;
        }
        $!hashed
    }

    method Capture() {
        Capture.new(hash => self!hashed)
    }
}
