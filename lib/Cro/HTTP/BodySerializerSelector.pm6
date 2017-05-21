use Cro::HTTP::BodySerializer;
use Cro::HTTP::Message;

class X::Cro::HTTP::BodySerializerSelector::NoneApplicable is Exception {
    method message() {
        "No applicable body serializer could be found for this message"
    }
}

role Cro::HTTP::BodySerializerSelector {
    method select(Cro::HTTP::Message, $body --> Cro::HTTP::BodySerializer) { ... }
}

class Cro::HTTP::BodySerializerSelector::RequestDefault does Cro::HTTP::BodySerializerSelector {
    my constant @defaults = [
    ];

    method select(Cro::HTTP::Message $message, $body --> Cro::HTTP::BodySerializer) {
        for @defaults {
            .return if .is-applicable($message, $body);
        }
        die X::Cro::HTTP::BodySerializerSelector::NoneApplicable.new;
    }
}

class Cro::HTTP::BodySerializerSelector::ResponseDefault does Cro::HTTP::BodySerializerSelector {
    my constant @defaults = [
        Cro::HTTP::BodySerializer::StrFallback,
        Cro::HTTP::BodySerializer::BlobFallback,
        Cro::HTTP::BodySerializer::SupplyFallback
    ];

    method select(Cro::HTTP::Message $message, $body --> Cro::HTTP::BodySerializer) {
        for @defaults {
            .return if .is-applicable($message, $body);
        }
        die X::Cro::HTTP::BodySerializerSelector::NoneApplicable.new;
    }
}

class Cro::HTTP::BodySerializerSelector::List does Cro::HTTP::BodySerializerSelector {
    has Cro::HTTP::BodySerializer @.serializers;

    method select(Cro::HTTP::Message $message, $body --> Cro::HTTP::BodySerializer) {
        for @!serializers {
            .return if .is-applicable($message, $body);
        }
        die X::Cro::HTTP::BodySerializerSelector::NoneApplicable.new;
    }
}

class Cro::HTTP::BodySerializerSelector::Prepend does Cro::HTTP::BodySerializerSelector {
    has Cro::HTTP::BodySerializer @.serializers;
    has Cro::HTTP::BodySerializerSelector $.next is required;

    method select(Cro::HTTP::Message $message, $body --> Cro::HTTP::BodySerializer) {
        for @!serializers {
            .return if .is-applicable($message, $body);
        }
        $!next.select($message, $body);
    }
}
