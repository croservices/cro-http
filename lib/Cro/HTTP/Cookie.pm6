use Cro::HTTP::DateTime;

my regex cookie-name { <[\x1F..\xFF] - [() \< \> @,;: \\ \x22 /\[\] ?={} \x20 \x1F \x7F]>+ };
subset CookieName of Str where /^ <cookie-name> $/;

my regex octet { <[\x21
                  \x23..\x2B
                  \x2D..\x3A
                  \x3C..\x5B
                  \x5D..\x7E]>*};
my regex cookie-value { [ <octet> || '("' <octet> '")' ] };
subset CookieValue of Str where /^ <cookie-value> $/;

my regex name  { <[\w\d]> (<[\w\d-]>* <[\w\d]>)* };
# In Domain regex first dot comes from
# RFC 6265 and is intended to be ignored.
my regex domain { '.'? (<name> ['.'<name>]*) }
subset Domain of Str where /^ <domain> $/;

my regex path { <[\x1F..\xFF] - [;]>+ }
subset Path of Str where /^ <path> $/;

class Cro::HTTP::Cookie {
    has CookieName $!name is required;
    has CookieValue $!value is required;
    has DateTime $!expires;
    has Duration $!max-age;
    has Domain $!domain;
    has Path $!path;
    has Bool $!secure;
    has Bool $!http-only;

    submethod BUILD(:$!name, :$!value,
                    :$!expires=Nil, :$!max-age=Nil,
                    :$!domain=Nil,:$!path=Nil,
                    :$!secure=False, :$!http-only=False) {};

    method !transform(DateTime $time) {
        my $rfc1123-format = sub ($self) { sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT",
                                           %weekdays{.day-of-week}, .day,
                                           %month-names{.month}, .year,
                                           .hour, .minute, .second given $self; }
        DateTime.new($time.Str, formatter => $rfc1123-format);
    }

    method to-set-cookie() {
        my $base = "$!name=$!value";
        $base ~= "; Expires={self!transform($!expires)}" if $!expires;
        $base ~= "; Max-Age=$!max-age" if $!max-age;
        $base ~= "; Domain=$!domain" if $!domain;
        $base ~= "; Path=$!path" if $!path;
        $base ~= "; Secure" if $!secure;
        $base ~= "; HttpOnly" if $!http-only;
        $base;
    }

    method to-cookie() { "$!name=$!value" }
    method from-set-cookie(Str $header) {  }
}

grammar CookieString {
    token TOP          { <cookie-pair> ['; ' <cookie-av> ]* }
    token cookie-pair  { <cookie-name> '=' <cookie-value> }
    token cookie-av    { <expires-av> || <max-age-av> || <domain-av> ||
                         <path-av> || <secure-av> || <httponly-av> || <extension-av> }
    token expires-av   { 'Expires=' <HTTP-date> }
    token max-age-av   { 'Max-Age=' <[1..9]> <[1..9]>* }
    token domain-av    { 'Domain=' <domain> }
    token path-av      { 'Path=' <path> }
    token secure-av    { 'Secure' }
    token httponly-av  { 'HttpOnly' }
    token extension-av { <path> }
}
