class Cro::HTTP::Exception is Exception {
    has Int $.status is required;
    has Str $.message;
}
