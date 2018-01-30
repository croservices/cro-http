use Cro::BodySerializerSelector;
use Cro::HTTP::BodySerializers;
use Cro::HTTP::Message;

class Cro::HTTP::BodySerializerSelector::RequestDefault does Cro::BodySerializerSelector {
    my constant @defaults = [
        Cro::HTTP::BodySerializer::WWWFormUrlEncoded,
        Cro::HTTP::BodySerializer::MultiPartFormData,
        Cro::HTTP::BodySerializer::JSON,
        Cro::HTTP::BodySerializer::StrFallback,
        Cro::HTTP::BodySerializer::BlobFallback
    ];

    method select(Cro::HTTP::Message $message, $body --> Cro::HTTP::BodySerializer) {
        for @defaults {
            .return if .is-applicable($message, $body);
        }
        die X::Cro::BodySerializerSelector::NoneApplicable.new;
    }
}

class Cro::HTTP::BodySerializerSelector::ResponseDefault does Cro::BodySerializerSelector {
    my constant @defaults = [
        Cro::HTTP::BodySerializer::JSON,
        Cro::HTTP::BodySerializer::StrFallback,
        Cro::HTTP::BodySerializer::BlobFallback,
        Cro::HTTP::BodySerializer::SupplyFallback
    ];

    method select(Cro::HTTP::Message $message, $body --> Cro::HTTP::BodySerializer) {
        for @defaults {
            .return if .is-applicable($message, $body);
        }
        die X::Cro::BodySerializerSelector::NoneApplicable.new;
    }
}
