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
            else {
                die "Unimplemented transfer encoding '$enc'";
            }
        }
        elsif $message.has-header('content-length') {
            Cro::HTTP::RawBodyParser::ContentLength
        }
        else {
            Cro::HTTP::RawBodyParser::UntilClosed
        }
    }
}
