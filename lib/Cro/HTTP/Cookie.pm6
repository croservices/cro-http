use DateTime::Parse;

class X::Cro::HTTP::Cookie::Unrecognized is Exception {
    has $.what;
    method message() {
        "Cookie string cannot be parsed. String value: $!what";
    }
}

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

grammar CookieString {
    token TOP          { <cookie-pair> ['; ' <cookie-av> ]* }
    token cookie-pair  { <cookie-name> '=' <cookie-value> }
    proto token cookie-av {*}
          token cookie-av:sym<expires>   { :i 'Expires=' [ <dt=DateTime::Parse::Grammar::rfc1123-date>    |
                                                           <dt=DateTime::Parse::Grammar::rfc850-date>     |
                                                           <dt=DateTime::Parse::Grammar::rfc850-var-date> |
                                                           <dt=DateTime::Parse::Grammar::asctime-date>    ] }
          token cookie-av:sym<max-age>   { :i 'Max-Age=' '-'? <[1..9]> <[0..9]>* }
          token cookie-av:sym<domain>    { :i 'Domain=' <domain> }
          token cookie-av:sym<path>      { :i 'Path=' <path> }
          token cookie-av:sym<secure>    { :i 'Secure' }
          token cookie-av:sym<httponly>  { :i 'HttpOnly' }
          token cookie-av:sym<extension> { :i <path> }
}

class Cro::HTTP::Cookie { ... }

class CookieBuilder {
    method TOP($/) {
        my ($name, $value) = $<cookie-pair>.made;
        my %args;
        %args.append('name',  $name);
        %args.append('value', $value);
        for $<cookie-av> -> $av {
            %args.append($av.made);
        };
        make Cro::HTTP::Cookie.new(|%args);
    }
    method cookie-pair($/) {
        make $/.split('=')
    }

    method !data-deal($str) {
        DateTime::Parse.new($str);
    }

    method cookie-av:sym<expires> ($/) {
        my $res = self!data-deal(~$/<dt>);
        make ('expires', $res);
    }
    method cookie-av:sym<max-age> ($/) {
        make ('max-age', Duration.new: (~$/).split('=')[1].Int);
    }
    method cookie-av:sym<domain> ($/) {
        make ('domain', $/.split('=')[1]);
    }
    method cookie-av:sym<path> ($/) {
        make ('path', $/.split('=')[1]);
    }
    method cookie-av:sym<secure> ($/) {
        make ('secure', True);
    }
    method cookie-av:sym<httponly> ($/) {
        make ('http-only', True);
    }
    method cookie-av:sym<extension> ($/) {}
}

class Cro::HTTP::Cookie {
    has CookieName $.name is required;
    has CookieValue $.value is required;
    has DateTime $.expires;
    has Duration $.max-age;
    has Domain $.domain;
    has Path $.path;
    has Bool $.secure;
    has Bool $.http-only;

    sub rfc1123-formatter(DateTime $_ --> DateTime) is export {
        my %month-names = 1 => 'Jan', 2 => 'Feb', 3 => 'Mar',
                          4 => 'Apr', 5 => 'May', 6 => 'Jun',
                          7 => 'Jul', 8 => 'Aug', 9 => 'Sep',
                          10 => 'Oct', 11 => 'Nov', 12 => 'Dec';
        my %amonth-names = %month-names.antipairs;

        my %weekdays = 1 => 'Mon', 2 => 'Tue',
                       3 => 'Wed', 4 => 'Thu',
                       5 => 'Fri', 6 => 'Sat',
                       7 => 'Sun';
        my %aweekdays = %weekdays.antipairs;

        my $rfc1123-format = sub ($self) { sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT",
                                           %weekdays{.day-of-week}, .day,
                                           %month-names{.month}, .year,
                                           .hour, .minute, .second given $self; }
        DateTime.new(.Str, formatter => $rfc1123-format);
    }

    submethod BUILD(:$!name, :$!value,
                    :$!expires=Nil, :$!max-age=Nil,
                    :$!domain=Nil,:$!path=Nil,
                    :$!secure=False, :$!http-only=False) {};

    method to-set-cookie() {
        my $base = "$!name=$!value";
        $base ~= "; Expires={rfc1123-formatter($!expires)}" if $!expires;
        $base ~= "; Max-Age=$!max-age" if $!max-age;
        $base ~= "; Domain=$!domain" if $!domain;
        $base ~= "; Path=$!path" if $!path;
        $base ~= "; Secure" if $!secure;
        $base ~= "; HttpOnly" if $!http-only;
        $base;
    }

    method to-cookie() { "$!name=$!value" }
    method from-set-cookie(Str $str) {
        my $cookie = CookieString.parse($str, :actions(CookieBuilder.new));
        die X::Cro::HTTP::Cookie::Unrecognized.new(what => $str) unless $cookie;
        $cookie.made;
    }
}
