use Cro::Policy::Timeout;

class Cro::HTTP::Exception is Exception {
    has Int $.status is required;
    has Str $.message;
}

class X::Cro::HTTP::Client::Timeout does X::Cro::Policy::Timeout {
    has $.uri;

    method message {
        "Exceeded timeout for $!phase when attempting to access $!uri"
    }
}
