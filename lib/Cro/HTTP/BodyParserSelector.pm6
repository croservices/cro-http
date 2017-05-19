use Cro::HTTP::BodyParser;
use Cro::HTTP::Message;

class X::Cro::HTTP::BodyParserSelector::NoneApplicable is Exception {
    method message() {
        "No applicable body parser could be found for this message"
    }
}

role Cro::HTTP::BodyParserSelector {
    method select(Cro::HTTP::Message --> Cro::HTTP::BodyParser) { ... }
}

class Cro::HTTP::BodyParserSelector::RequestDefault does Cro::HTTP::BodyParserSelector {
    my constant @defaults = [
        Cro::HTTP::BodyParser::WWWFormUrlEncoded,
        Cro::HTTP::BodyParser::MultiPartFormData,
        Cro::HTTP::BodyParser::TextFallback,
        Cro::HTTP::BodyParser::BlobFallback
    ];

    method select(Cro::HTTP::Message $message --> Cro::HTTP::BodyParser) {
        for @defaults {
            .return if .is-applicable($message);
        }
        die X::Cro::HTTP::BodyParserSelector::NoneApplicable.new;
    }
}

class Cro::HTTP::BodyParserSelector::ResponseDefault does Cro::HTTP::BodyParserSelector {
    my constant @defaults = [
        Cro::HTTP::BodyParser::TextFallback,
        Cro::HTTP::BodyParser::BlobFallback
    ];

    method select(Cro::HTTP::Message $message --> Cro::HTTP::BodyParser) {
        for @defaults {
            .return if .is-applicable($message);
        }
        die X::Cro::HTTP::BodyParserSelector::NoneApplicable.new;
    }
}

class Cro::HTTP::BodyParserSelector::List does Cro::HTTP::BodyParserSelector {
    has Cro::HTTP::BodyParser @.parsers;

    method select(Cro::HTTP::Message $message --> Cro::HTTP::BodyParser) {
        for @!parsers {
            .return if .is-applicable($message);
        }
        die X::Cro::HTTP::BodyParserSelector::NoneApplicable.new;
    }
}

class Cro::HTTP::BodyParserSelector::Prepend does Cro::HTTP::BodyParserSelector {
    has Cro::HTTP::BodyParser @.parsers;
    has Cro::HTTP::BodyParserSelector $.next is required;

    method select(Cro::HTTP::Message $message --> Cro::HTTP::BodyParser) {
        for @!parsers {
            .return if .is-applicable($message);
        }
        $!next.select($message);
    }
}
