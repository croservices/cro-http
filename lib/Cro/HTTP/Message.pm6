use Cro::MediaType;
use Cro::MessageWithBody;
use Cro::HTTP::Header;

role Cro::HTTP::Message does Cro::MessageWithBody {
    #| The HTTP version used for the request
    has Str $.http-version is rw;

    #| If this is a HTTP/2.0 request, the stream ID
    has Int $.http2-stream-id is rw;

    #| The headers associated with this message.
    has Cro::HTTP::Header @!headers;

    has Cro::MediaType $!cached-content-type;

    #| Get a list of headers, as Cro::HTTP::Header objects
    method headers() {
        @!headers.List
    }

    #| Append a header to the HTTP message
    multi method append-header(Cro::HTTP::Header $header --> Nil) {
        @!headers.push($header);
        $!cached-content-type = Nil;
    }

    #| Append a header to the HTTP message (the string must parse as a valid
    #| HTTP header, such as 'Content-type: text/html')
    multi method append-header(Str $header --> Nil) {
        @!headers.push(Cro::HTTP::Header.parse($header));
        $!cached-content-type = Nil;
    }

    #| Append a header to the HTTP message by specifying its name and value
    multi method append-header(Str $name, Str(Cool) $value --> Nil) {
        @!headers.push(Cro::HTTP::Header.new(:$name, :$value));
        $!cached-content-type = Nil;
    }

    #| Append a header to the HTTP message using a Pair, where the key is the
    #| header name and the value is the header value
    multi method append-header(Pair $header --> Nil) {
        @!headers.push(Cro::HTTP::Header.new(name => $header.key, value => $header.value));
        $!cached-content-type = Nil;
    }

    #| Remove all headers with the specified name; returns the number of
    #| headers that were removed
    multi method remove-header(Str $name --> Int) {
        my $folded = $name.fc;
        my $removed = 0;
        @!headers .= grep({ not .name.fc eq $folded && ++$removed });
        $!cached-content-type = Nil;
        $removed
    }

    #| Remove a header matching the specified predicate; returns the number
    #| of headers that removed
    multi method remove-header(&predicate --> Int) {
        my $removed = 0;
        @!headers .= grep({ not predicate($_) && ++$removed });
        $!cached-content-type = Nil;
        $removed
    }

    #| Remove the exact header passed (compared by object equality, so this
    #| must have been obtained by first calling the headers method on this
    #| message); returns the number of headers removed
    multi method remove-header(Cro::HTTP::Header $header --> Int) {
        my $removed = 0;
        @!headers .= grep({ not $_ === $header && ++$removed });
        $!cached-content-type = Nil;
        $removed
    }

    #| Checks if the message has a header with the specified name
    method has-header(Str $header-name --> Bool) {
        my $folded = $header-name.fc;
        so @!headers.first(*.name.fc eq $folded)
    }

    #| Get the header with the specified name as a string; if there are
    #| many headers with that name, their values will be joined with a
    #| comma, and Nil will be returned if there are no headers
    method header(Str $header-name) {
        my $folded = $header-name.fc;
        my @matching := @!headers.grep(*.name.fc eq $folded).list;
        @matching == 1
            ?? @matching[0].value
            !! @matching == 0
                ?? Nil
                !! @matching.map(*.value).join(',')
    }

    #| Get the value(s) of the header(s) with the specified name as a
    #| List; if there is no header with such a name, the list will be empty
    method header-list(Str $header-name) {
        my $folded = $header-name.fc;
        @!headers.grep(*.name.fc eq $folded).map(*.value).list
    }

    method !headers-str() {
        @!headers.map({ .name ~ ": " ~ .value ~ "\r\n" }).join
    }

    #| Gets a Cro::MediaType object representing the Content-type header of
    #| the message, and returning Nil if there is no such header
    method content-type() {
        with $!cached-content-type {
            $_
        }
        orwith self.header('content-type') {
            $!cached-content-type = Cro::MediaType.parse($_)
        }
        else {
            Nil
        }
    }

    #| Determines the encoding of the message, preferentially by looking
    #| for a charset parameter in the content-type, but falling back to
    #| trying to infer the encoding from the content of the specified
    #| blob; may return a List of potential encodings
    method body-text-encoding(Blob $blob) {
        my $encoding;
        with self.content-type {
            with .parameters.first(*.key.fc eq 'charset') {
                $encoding = .value;
            }
        }
        without $encoding {
            # Decoder drops the BOM by itself, if it exists, so just use
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
        $encoding // ('utf-8', 'latin-1')
    }
}
