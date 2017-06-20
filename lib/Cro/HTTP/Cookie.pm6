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

    submethod BUILD(:$!name, :$!value) {};

    method to-set-cookie() {}
    method to-cookie() {}
    method from-set-cookie(Str $header) {}
}

my regex time { [\d\d ':'] ** 2 [\d\d] };
my regex wkday { 'Mon' | 'Tue' | 'Wed' | 'Thu' | 'Fri' | 'Sat' | 'Sun' };
my regex weekday { 'Monday' | 'Tuesday' | 'Wednesday' | 'Thursday' |
                   'Friday' | 'Saturday' | 'Sunday' };
my regex month { 'Jan' | 'Feb' | 'Mar' | 'Apr' | 'May' | 'Jun'
                 'Jul' | 'Aug' | 'Sep' | 'Oct' | 'Nov' | 'Dec' };

my regex date1 { \d\d ' ' <month>  ' ' \d ** 4 };
my regex date2 { \d\d '-' <month>  '-' \d ** 2 };
my regex date3 { <month> ' ' [\d\d | ' ' \d] };

my regex rfc1123-date { <wkday> ', ' <date1> ' ' <time> ' GMT' };
my regex rfc850-date { <weekday> ', ' <date2> ' ' <time> ' GMT' };
my regex asctime-date { <wkday> ' ' <date3> ' ' <time> ' ' \d ** 4 };

our regex HTTP-date { <rfc1123-date> || <rfc850-date> || <asctime-date> };

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
