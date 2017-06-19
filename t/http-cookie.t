use Cro::HTTP::Cookie;
use Test;

lives-ok { my CookieName $cn = "GoodName"; }, 'Correct cookie names are into the subset';

dies-ok { my CookieName $cn = ""; }, "Empty cookie name is now allowed";

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

dies-ok { Cro::HTTP::Cookie.new }, 'Cookie cannot be created with no arguments';
dies-ok { Cro::HTTP::Cookie.new: name => 'UID' }, 'Cookie cannot be created without value';
dies-ok { Cro::HTTP::Cookie.new: value => 'TEST' }, 'Cookie cannot be created without name';
lives-ok { Cro::HTTP::Cookie.new(name => "UID", value => "TEST"); }, 'Cookie can be created';

my $c = Cro::HTTP::Cookie.new(name => "UID", value => "TEST");

dies-ok { $c.name      = 'new' }, 'New is read only';
dies-ok { $c.value     = 'new' }, 'Value is read only';
dies-ok { $c.expires   = 'new' }, 'Expires is read only';
dies-ok { $c.max-age   = 'new' }, 'Max-age is read only';
dies-ok { $c.domain    = 'new' }, 'Domain is read only';
dies-ok { $c.path      = 'new' }, 'Path is read only';
dies-ok { $c.http-only = 'new' }, 'Http-only is read only';
