use Cro::HTTP::BodySerializer;
use Cro::HTTP::Message;

class X::Cro::HTTP::BodySerializerSelector::NoneApplicable is Exception {
    method message() {
        "No applicable body serializer could be found for this message"
    }
}

role Cro::HTTP::BodySerializerSelector {
    method select(Cro::HTTP::Message --> Cro::HTTP::BodySerializer) { ... }
}

class Cro::HTTP::BodySerializerSelector::RequestDefault does Cro::HTTP::BodySerializerSelector {
    my constant @defaults = [
    ];

    method select(Cro::HTTP::Message $message --> Cro::HTTP::BodySerializer) {
        for @defaults {
            .return if .is-applicable($message);
        }
        die X::Cro::HTTP::BodySerializerSelector::NoneApplicable.new;
    }
}

class Cro::HTTP::BodySerializerSelector::ResponseDefault does Cro::HTTP::BodySerializerSelector {
    my constant @defaults = [
    ];

    method select(Cro::HTTP::Message $message --> Cro::HTTP::BodySerializer) {
        for @defaults {
            .return if .is-applicable($message);
        }
        die X::Cro::HTTP::BodySerializerSelector::NoneApplicable.new;
    }
}

class Cro::HTTP::BodySerializerSelector::List does Cro::HTTP::BodySerializerSelector {
    has Cro::HTTP::BodySerializer @.serializers;

    method select(Cro::HTTP::Message $message --> Cro::HTTP::BodySerializer) {
        for @!serializers {
            .return if .is-applicable($message);
        }
        die X::Cro::HTTP::BodySerializerSelector::NoneApplicable.new;
    }
}

class Cro::HTTP::BodySerializerSelector::Prepend does Cro::HTTP::BodySerializerSelector {
    has Cro::HTTP::BodySerializer @.serializers;
    has Cro::HTTP::BodySerializerSelector $.next is required;

    method select(Cro::HTTP::Message $message --> Cro::HTTP::BodySerializer) {
        for @!serializers {
            .return if .is-applicable($message);
        }
        $!next.select($message);
    }
}
