use Cro::HTTP::Cookie;
use Test;

lives-ok { my CookieName $cn = "GoodName"; }, 'Correct cookie names are into the subset';

dies-ok { my CookieName $cn = ""; }, "Empty cookie name is now allowed";

dies-ok { my CookieValue $cv = '("cookie-octet")'; }, 'No parens allowed in a cookie';

lives-ok { my CookieValue $cv = '"cookie-octet"'; }, 'Cookie octet can be wrapped in double quotes';

my @bad-chars = "\x00"..."\x1F", "\x7F", '(', ')',
            '<', '>', '@', ',', ';', ':', '\\',
            '"', '/', '[', ']', '?', '=', '{',
            '}', ' ';
subtest {
    for @bad-chars -> $char {
        dies-ok { my CookieName $ch = "Name$char"; };
    }
}, "Incorrect symbols are outside of CookieName subset";


lives-ok { my CookieValue $cv = "Test"; }, 'Correct cookie values are into the subset';

lives-ok { my CookieValue $cv = ""; }, "Empty cookie value is allowed";

@bad-chars = "\x22", "\x2C", "\x3B", "\x5C";
@bad-chars.push:  "\x7F"..."\xFF";
subtest {
    for @bad-chars -> $char {
        dies-ok { my CookieValue $cv = "Name$char"; };
    }
}, "Incorrect symbols are outside of CookieValue subset";

lives-ok {
    my Domain $d;
    $d = "www.example.com";
    $d = "example.com";
    $d = "127domain.com";
}, 'Correct domain name works';
dies-ok { my Domain $d = "\n"; }, 'Incorrect domain name with bad character';
dies-ok { my Domain $d = ""; }, 'Empty domain name cannot be created';
dies-ok { my Domain $d = ' '; }, 'Domain name cannot contain spaces';

isnt Cro::HTTP::Cookie::CookieString.parse('SID=31d4d86e407aad42; Path=/; Domain=example.com'), Nil, 'Set-Cookie string 1 parses';
isnt Cro::HTTP::Cookie::CookieString.parse('lang=en-US; Path=/; Domain=example.com'), Nil, 'Set-Cookie string 2 parses';
isnt Cro::HTTP::Cookie::CookieString.parse('lang=; Expires=Sun, 06 Nov 1994 08:49:37 GMT'), Nil, 'Set-Cookie string 3 parses';
isnt Cro::HTTP::Cookie::CookieString.parse('cookie_name=value;path=/'), Nil,
        'Set-Cookie ala buggy Tomcat (missing space); we tolerate this';

# Cookie class
dies-ok { Cro::HTTP::Cookie.new }, 'Cookie cannot be created with no arguments';
dies-ok { Cro::HTTP::Cookie.new: name => 'UID' }, 'Cookie cannot be created without value';
dies-ok { Cro::HTTP::Cookie.new: value => 'TEST' }, 'Cookie cannot be created without name';
lives-ok { Cro::HTTP::Cookie.new(name => "UID", value => "TEST"); }, 'Cookie can be created';

my $c = Cro::HTTP::Cookie.new(name => "UID", value => "TEST");
my $cookie;

dies-ok { $c.name      = 'new' }, 'New is read only';
dies-ok { $c.value     = 'new' }, 'Value is read only';
dies-ok { $c.expires   = DateTime.now }, 'Expires is read only';
dies-ok { $c.max-age   = Duration.new(3600) }, 'Max-age is read only';
dies-ok { $c.domain    = 'new' }, 'Domain is read only';
dies-ok { $c.path      = '/'   }, 'Path is read only';
dies-ok { $c.secure    = True  }, 'Secure is read only';
dies-ok { $c.http-only = True  }, 'Http-only is read only';
dies-ok { $c.same-site = Cro::HTTP::Cookie::SameSite::Strict }, 'SameSite is read only';

is $c.to-set-cookie, 'UID=TEST', 'Set cookie 1 works';
is $c.to-cookie, 'UID=TEST', 'Cookie 1 works';

$cookie = Cro::HTTP::Cookie.from-set-cookie: $c.to-set-cookie;
is $cookie.to-set-cookie, 'UID=TEST', 'Cookie 1 can be parsed';

my DateTime $datetime = DateTime.new(
    year    => 2017,
    month   => 1,
    day     => 1,
    hour    => 12,
    minute  => 5);
$c = Cro::HTTP::Cookie.new(name => "UID", value => "TEST", expires => $datetime);
is $c.to-set-cookie, 'UID=TEST; Expires=Sun, 01 Jan 2017 12:05:00 GMT', 'Set cookie 2 works';
is $c.to-cookie, 'UID=TEST', 'Cookie 2 works';

$cookie = Cro::HTTP::Cookie.from-set-cookie: $c.to-set-cookie;
is $cookie.to-set-cookie, 'UID=TEST; Expires=Sun, 01 Jan 2017 12:05:00 GMT', 'Cookie 2 can be parsed';

my Duration $d = Duration.new: 3600;
$c = Cro::HTTP::Cookie.new(name => "UID", value => "TEST", max-age => $d);
is $c.to-set-cookie, "UID=TEST; Max-Age=$d", 'Set cookie 3 works';
is $c.to-cookie, "UID=TEST", 'Cookie 3 works';

$cookie = Cro::HTTP::Cookie.from-set-cookie: $c.to-set-cookie;
is $cookie.to-set-cookie, "UID=TEST; Max-Age=$d", 'Cookie 3 can be parsed';

$c = Cro::HTTP::Cookie.new(name => "UID", value => "TEST",
                           max-age => $d, secure => True,
                           http-only => True);
is $c.to-set-cookie, "UID=TEST; Max-Age=$d; Secure; HttpOnly", 'Set cookie 4 works';
is $c.to-cookie, 'UID=TEST', 'Cookie 4 works';

$cookie = Cro::HTTP::Cookie.from-set-cookie: $c.to-set-cookie;
is $cookie.to-set-cookie, "UID=TEST; Max-Age=$d; Secure; HttpOnly", 'Cookie 4 can be parsed';

# SameSite tests
$cookie = quietly Cro::HTTP::Cookie.from-set-cookie: 'mycookie=raisin; SameSite=Dog';
is $cookie.to-set-cookie, 'mycookie=raisin', 'Invalid SameSite value discarded';

for (
    'mycookie=raisin; SameSite=Strict',
    'mycookie=raisin; SameSite=Lax',
    'mycookie=raisin; SameSite=None',
).kv -> $i, $cookie-str {
    my $cookie = Cro::HTTP::Cookie.from-set-cookie: $cookie-str;
    is $cookie.to-set-cookie, $cookie-str, "Valid SameSite value cookie $i can be parsed";
}

$cookie = Cro::HTTP::Cookie.from-set-cookie: q"sisapweb=6fbaab42-f066-4c03-82f9-5565c5fe2e46;Version=1;Path=/;Secure;HttpOnly";
is $cookie.path, '/', 'Correct path after extension';
ok $cookie.secure, 'Secure parsed after extension';
is-deeply $cookie.extensions, { :Version('1') }, 'Extensions are parsed and extracted also';

done-testing;
