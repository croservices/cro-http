subset CookieName of Str where /^ <[\x1F..\xFF] - [() \< \> @,;: \\ \x22 /\[\] ?={} \x20 \x1F \x7F]>+ $/;

my regex octet { <[\x21
                  \x23..\x2B
                  \x2D..\x3A
                  \x3C..\x5B
                  \x5D..\x7E]>*};
subset CookieValue of Str where /^ (<octet> || '("' <octet> '")' ) $/;

class Cro::HTTP::Cookie {
    has CookieName $!name;
    has CookieValue $!value;
    has DateTime $!expires;
    has Duration $!max-age;
    has Str $!domain;
    has Str $!path;
    has Bool $!secure;
    has Bool $!http-only;

    submethod BUILD() {
    }

    method to-set-cookie() {}
    method to-cookie() {}
    method from-set-cookie() {}
}
