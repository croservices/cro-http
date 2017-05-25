use Cro::HTTP::Body;
use Cro::HTTP::Header;
use Cro::HTTP::Message;
use Cro::MediaType;
use JSON::Fast;

role Cro::HTTP::BodyParser {
    method is-applicable(Cro::HTTP::Message $message --> Bool) { ... }
    method parse(Cro::HTTP::Message $message --> Promise) { ... }
}

class Cro::HTTP::BodyParser::BlobFallback does Cro::HTTP::BodyParser {
    method is-applicable(Cro::HTTP::Message $message --> Bool) {
        True
    }

    method parse(Cro::HTTP::Message $message --> Promise) {
        $message.body-blob
    }
}

class Cro::HTTP::BodyParser::TextFallback does Cro::HTTP::BodyParser {
    method is-applicable(Cro::HTTP::Message $message --> Bool) {
        ($message.header('content-type') // '').starts-with('text/')
    }

    method parse(Cro::HTTP::Message $message --> Promise) {
        $message.body-text
    }
}

class Cro::HTTP::BodyParser::WWWFormUrlEncoded does Cro::HTTP::BodyParser {
    has Str $.default-encoding = 'utf-8';

    method default-encoding() {
        self ?? $!default-encoding !! 'utf-8'
    }

    method is-applicable(Cro::HTTP::Message $message --> Bool) {
        ($message.header('content-type') // '') eq 'application/x-www-form-urlencoded'
    }

    method parse(Cro::HTTP::Message $message --> Promise) {
        Promise(supply {
            my $payload = '';
            whenever $message.body-byte-stream -> $blob {
                # Per spec, should only have octets 0x00-0x7F, with higher
                # ones %-encoded.
                $payload ~= $blob.decode('ascii');
                LAST emit Cro::HTTP::Body::WWWFormUrlEncoded.new(
                    pairs => decode-payload-to-pairs()
                );
            }

            sub decode-payload-to-pairs() {
                my @pairs;
                my int @name-tweak;
                my int @value-tweak;
                my $encoding = self.default-encoding;
                for $payload.split('&') -> Str $string {
                    my Str $string-sp = $string.subst('+', ' ', :g);
                    my int $eq-idx = $string-sp.index('=');
                    my Str $name = $eq-idx >= 0
                        ?? $string-sp.substr(0, $eq-idx)
                        !! $string-sp;
                    my Str $value = $eq-idx >= 0
                        ?? $string-sp.substr($eq-idx + 1)
                        !! '';

                    if $name eq '_charset_' && $value {
                        $encoding = $value;
                    }

                    my $name-non-ascii = False;
                    if $name.contains('%') {
                        $name .= subst(:g, /'%' (<[A..Fa..f0..9]>**2)/, {
                            my $ord = :16(.[0].Str);
                            $name-non-ascii = True if $ord >= 128;
                            chr($ord)
                        });
                    }
                    @name-tweak.push(@pairs.elems) if $name-non-ascii;

                    my $value-non-ascii = False;
                    if $value.contains('%') {
                        $value .= subst(:g, /'%' (<[A..Fa..f0..9]>**2)/, {
                            my $ord = :16(.[0].Str);
                            $value-non-ascii = True if $ord >= 128;
                            chr($ord)
                        });
                    }
                    @value-tweak.push(@pairs.elems) if $value-non-ascii;

                    @pairs.push($name => $value);
                }

                for @name-tweak -> $idx {
                    my $p = @pairs[$idx];
                    @pairs[$idx] = $p.key.encode('latin-1').decode($encoding) => $p.value;
                }
                for @value-tweak -> $idx {
                    my $p = @pairs[$idx];
                    @pairs[$idx] = $p.key => $p.value.encode('latin-1').decode($encoding);
                }

                return @pairs;
            }
        })
    }
}

class Cro::HTTP::BodyParser::MultiPartFormData does Cro::HTTP::BodyParser {
    method is-applicable(Cro::HTTP::Message $message --> Bool) {
        with $message.content-type {
            .type eq 'multipart' && .subtype eq 'form-data'
        }
        else {
            False
        }
    }

    method parse(Cro::HTTP::Message $message --> Promise) {
        Promise(supply {
            my $boundary = $message.content-type.parameters.first(*.key.lc eq 'boundary');
            without $boundary {
                die "Missing boundary parameter in for 'multipart/form-data'";
            }

            my $payload = '';
            whenever $message.body-byte-stream -> $blob {
                # Decode as latin-1 to cheaply find boundaries.
                $payload ~= $blob.decode('latin-1');
                LAST emit parse();
            }

            sub parse() {
                # Locate start of significant body.
                my $dd-boundary = "--$boundary.value()";
                my $start = $payload.index($dd-boundary);
                without $start {
                    die "Could not find starting boundary of multipart/form-data";
                }

                # Extract all the parts.
                my $search = "\r\n$dd-boundary";
                $payload .= substr($start + $dd-boundary.chars);
                my @part-strs;
                loop {
                    last if $payload.starts-with('--');
                    my $end-boundary-line = $payload.index("\r\n");
                    without $end-boundary-line {
                        die "Missing line terminator after multipart/form-data boundary";
                    }
                    if $end-boundary-line != 0 {
                        if $payload.substr(0, $end-boundary-line) !~~ /\h+/ {
                            die "Unexpected text after multpart/form-data boundary " ~
                                "('$end-boundary-line')";
                        }
                    }

                    my $next-boundary = $payload.index($search);
                    without $next-boundary {
                        die "Unable to find boundary after part in multipart/form-data";
                    }
                    my $start = $end-boundary-line + 1;
                    @part-strs.push($payload.substr($start, $next-boundary - $start));
                    $payload .= substr($next-boundary + $search.chars);
                }

                my @parts;
                for @part-strs -> Str $part {
                    my ($header, $body-str) = $part.split("\r\n\r\n", 2);
                    my @headers = $header.split("\r\n").map: { Cro::HTTP::Header.parse($_) };
                    with @headers.first(*.name.lc eq 'content-disposition') {
                        my $param-start = .value.index(';');
                        my $parameters = $param-start ?? .value.substr($param-start) !! Str;
                        without $parameters {
                            die "Missing content-disposition parameters in multipart/form-data part";
                        }
                        my $param-parse = Cro::MediaType::Grammar.parse(
                            $parameters, :rule<parameters>,
                            :actions(Cro::MediaType::Actions)
                        );
                        without $param-parse {
                            die "Could not parse content-disposition parameters in multipart/formdata";
                        }
                        my @params := $param-parse.ast.list;
                        my $name-param = @params.first(*.key.lc eq 'name');
                        without $name-param {
                            die "Missing name parameter in content-disposition of multipart/formdata";
                        }
                        my $field-name = $name-param.value;
                        my $filename-param = @params.first(*.key.lc eq 'filename');
                        my $filename = $filename-param ?? $filename-param.value !! Str;
                        my $body-blob = $body-str.encode('latin-1');
                        push @parts, Cro::HTTP::Body::MultiPartFormData::Part.new(
                            :@headers, :$field-name, :$filename, :$body-blob
                        );
                    }
                    else {
                        die "Missing content-disposition header in multipart/form-data part";
                    }
                }
                return Cro::HTTP::Body::MultiPartFormData.new(:@parts);
            }
        })
    }
}

class Cro::HTTP::BodyParser::JSON does Cro::HTTP::BodyParser {
    method is-applicable(Cro::HTTP::Message $message --> Bool) {
        with $message.content-type {
            .type eq 'application' && .subtype eq 'json' || .suffix eq 'json'
        }
        else {
            False
        }
    }

    method parse(Cro::HTTP::Message $message --> Promise) {
        Promise(supply {
            my $payload = Blob.new;
            whenever $message.body-byte-stream -> $blob {
                $payload ~= $blob;
                LAST emit from-json($payload.decode('utf-8'));
            }
        })
    }
}
