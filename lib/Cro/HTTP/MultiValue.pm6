class Cro::HTTP::MultiValue is List does Stringy {
    multi method Stringy(::?CLASS:D:) {
        self.Str
    }

    multi method Str(::?CLASS:D:) {
        self.join(',')
    }
}
