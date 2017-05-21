use Cro::HTTP::Message;

role Cro::HTTP::BodySerializer {
    method is-applicable(Cro::HTTP::Message $message --> Bool) { ... }
    method serialize(Cro::HTTP::Message $message --> Supply) { ... }
}
