use DateTime::Parse;

class X::Cro::HTTP::Cookie::Unrecognized is Exception {
    has $.what;
    method message() {
        "Cookie string cannot be parsed. String value: $!what";
    }
}

my regex cookie-name { <[\x1F..\xFF] - [() \< \> @,;: \\ \x22 /\[\] ?={} \x20 \x1F \x7F]>+ };
my subset CookieName of Str is export where /^ <cookie-name> $/;

my regex octet { <[\x21
                  \x23..\x2B
                  \x2D..\x3A
                  \x3C..\x5B
                  \x5D..\x7E]>*};
my regex cookie-value { [ <octet> || '"' <octet> '"' ] };
my subset CookieValue of Str is export where /^ <cookie-value> $/;

my regex name  { <[\w\d]> (<[\w\d-]>* <[\w\d]>)* };
# In Domain regex first dot comes from
# RFC 6265 and is intended to be ignored.
my regex domain { '.'? (<name> ['.'<name>]*) }
my subset Domain of Str is export where /^ <domain> $/;

my regex path { <[\x1F..\xFF] - [;]>+ }
my subset Path of Str is export where /^ <path> $/;

enum Cro::HTTP::Cookie::SameSite ( |do {
    # Make key and value the same so that it is straight-forward to map back to enum
    <
        Strict
        Lax
        None
    >.map: { $_ => $_ }
});

grammar Cro::HTTP::Cookie::CookieString {
    my @same-site-opts = Cro::HTTP::Cookie::SameSite.enums.values;

    token TOP          { <cookie-pair> [';' ' '? <cookie-av> ]* }
    token cookie-pair  { <cookie-name> '=' <cookie-value> <.drop-illegal-post-value> }
    token drop-illegal-post-value {
        # Cope with illegal (per-RFC) things that trail the cookie value.
        <-[;]>*
    }
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
          token cookie-av:sym<samesite>  { :i 'SameSite=' @same-site-opts }
          token cookie-av:sym<extension> { <path> }
}

class Cro::HTTP::Cookie { ... }

class Cro::HTTP::Cookie::CookieBuilder {
    my class Extension {
        has @.extension is required;
    }

    method TOP($/) {
        my ($name, $value) = $<cookie-pair>.made;
        my %args = :$name, :$value;
        my %extensions;
        for $<cookie-av> -> $av {
            given $av.made {
                when Extension {
                    %extensions.append(.extension);
                }
                default {
                    %args{$_[0]} //= $_[1];
                }
            }
        };
        %args<extensions> = %extensions if %extensions;
        make Cro::HTTP::Cookie.new(|%args);
    }

    method cookie-pair($/) {
        make (~$<cookie-name>, ~$<cookie-value>)
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
    method cookie-av:sym<samesite> ($/) {
        make ('same-site', Cro::HTTP::Cookie::SameSite($/.split('=')[1].tclc));
    }
    method cookie-av:sym<extension> ($/) {
        my @parts = $/.split('=');
        make Extension.new(:extension(@parts[0], @parts[1] // True));
    }
}

#| Represents a HTTP cookie from the server-side perspective, including the
#| details of its expiration and the constraints on when it should be sent
#| back by the client
class Cro::HTTP::Cookie {
    has CookieName $.name is required;
    has CookieValue $.value is required;
    has DateTime $.expires;
    has Duration $.max-age;
    has Domain $.domain;
    has Path $.path;
    has Bool $.secure;
    has Bool $.http-only;
    has Cro::HTTP::Cookie::SameSite $.same-site;
    has %.extensions;

    sub rfc1123-formatter(DateTime $_ --> DateTime) is export {
        my constant %month-names = 1 => 'Jan', 2 => 'Feb', 3 => 'Mar',
                          4 => 'Apr', 5 => 'May', 6 => 'Jun',
                          7 => 'Jul', 8 => 'Aug', 9 => 'Sep',
                          10 => 'Oct', 11 => 'Nov', 12 => 'Dec';
        my constant %weekdays = 1 => 'Mon', 2 => 'Tue',
                       3 => 'Wed', 4 => 'Thu',
                       5 => 'Fri', 6 => 'Sat',
                       7 => 'Sun';

        my $rfc1123-format = sub ($self) { sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT",
                                           %weekdays{.day-of-week}, .day,
                                           %month-names{.month}, .year,
                                           .hour, .minute, .second given $self.utc; }
        DateTime.new(.Str, formatter => $rfc1123-format);
    }

    submethod BUILD(:$!name, :$!value,
                    :$!expires=Nil, :$!max-age=Nil,
                    :$!domain=Nil,:$!path=Nil,
                    :$!secure=False, :$!http-only=False,
                    :$!same-site=Nil, :%!extensions) {};

    #| Turns the cookie information into a value to used in a Set-cookie header
    method to-set-cookie(--> Str) {
        my $base = "$!name=$!value";
        $base ~= "; Expires={rfc1123-formatter($!expires)}" if $!expires;
        $base ~= "; Max-Age=$!max-age" if $!max-age;
        $base ~= "; Domain=$!domain" if $!domain;
        $base ~= "; Path=$!path" if $!path;
        $base ~= "; Secure" if $!secure;
        $base ~= "; HttpOnly" if $!http-only;
        $base ~= "; SameSite={$!same-site.key}" if $!same-site.defined;
        $base;
    }

    #| Turns the cookie into a name=value string, for sending to a server
    method to-cookie(--> Str) { "$!name=$!value" }

    #| Parses the value part of a Set-cookie header into a Cro::HTTP::Cookie
    #| instance
    method from-set-cookie(Str $str --> Cro::HTTP::Cookie) {
        my $cookie = Cro::HTTP::Cookie::CookieString.parse($str, :actions(Cro::HTTP::Cookie::CookieBuilder.new));
        die X::Cro::HTTP::Cookie::Unrecognized.new(what => $str) unless $cookie;
        $cookie.made;
    }
}
