use Cro::HTTP::Message;
use Cro::HTTP::RawBodyParser;

role Cro::HTTP::RawBodyParserSelector {
    method select(Cro::HTTP::Message --> Cro::HTTP::RawBodyParser) { ... }
}

class Cro::HTTP::RawBodyParserSelector::Default does Cro::HTTP::RawBodyParserSelector {
    method select(Cro::HTTP::Message $message --> Cro::HTTP::RawBodyParser) {
        with $message.header('transfer-encoding') -> $enc-value {
            my $enc = $enc-value.trim.lc;
            if $enc eq 'chunked' {
                Cro::HTTP::RawBodyParser::Chunked
            }
            elsif $enc eq 'identity' {
                from-headers($message);
            }
            else {
                die "Unimplemented transfer encoding '$enc'";
            }
        }
        else {
            from-headers($message);
        }
    }

    sub from-headers(Cro::HTTP::Message $message --> Cro::HTTP::RawBodyParser ) {
        if $message.has-header('content-length') {
            Cro::HTTP::RawBodyParser::ContentLength
        }
        else {
            Cro::HTTP::RawBodyParser::UntilClosed
        }
    }
}
