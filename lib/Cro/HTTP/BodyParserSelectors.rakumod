use Cro::BodyParserSelector;
use Cro::HTTP::BodyParsers;
use Cro::HTTP::Message;

class Cro::HTTP::BodyParserSelector::RequestDefault does Cro::BodyParserSelector {
    my constant @defaults = [
        Cro::HTTP::BodyParser::WWWFormUrlEncoded,
        Cro::HTTP::BodyParser::MultiPartFormData,
        Cro::HTTP::BodyParser::JSON,
        Cro::HTTP::BodyParser::TextFallback,
        Cro::HTTP::BodyParser::BlobFallback
    ];

    method select(Cro::HTTP::Message $message --> Cro::BodyParser) {
        for @defaults {
            .return if .is-applicable($message);
        }
        die X::Cro::BodyParserSelector::NoneApplicable.new;
    }
}

class Cro::HTTP::BodyParserSelector::ResponseDefault does Cro::BodyParserSelector {
    my constant @defaults = [
        Cro::HTTP::BodyParser::JSON,
        Cro::HTTP::BodyParser::TextFallback,
        Cro::HTTP::BodyParser::BlobFallback
    ];

    method select(Cro::HTTP::Message $message --> Cro::BodyParser) {
        for @defaults {
            .return if .is-applicable($message);
        }
        die X::Cro::BodyParserSelector::NoneApplicable.new;
    }
}
