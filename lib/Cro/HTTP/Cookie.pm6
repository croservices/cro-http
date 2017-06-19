subset CookieName of Str where /^ <[\x1F..\xFF] - [() \< \> @,;: \\ \x22 /\[\] ?={} \x20 \x1F \x7F]>+ $/;

my regex octet { <[\x21
                  \x23..\x2B
                  \x2D..\x3A
                  \x3C..\x5B
                  \x5D..\x7E]>*};
subset CookieValue of Str where /^ (<octet> || '("' <octet> '")' ) $/;

my regex name  { <[\w\d]> (<[\w\d-]>* <[\w\d]>)* };
# In Domain regex first dot comes from
# RFC 6265 and is intended to be ignored.
subset Domain of Str where /^ '.'? (<name> ('.'<name>)*) $/;

subset Path of Str where /^ <[\x1F..\xFF] - [;]>+ $/;

class Cro::HTTP::Cookie {
    has CookieName $!name is required;
    has CookieValue $!value is required;
    has DateTime $!expires;
    has Duration $!max-age;
    has Domain $!domain;
    has Path $!path;
    has Bool $!secure;
    has Bool $!http-only;

    submethod BUILD(:$!name, :$!value) {};

    method to-set-cookie() {}
    method to-cookie() {}
    method from-set-cookie() {}
}
