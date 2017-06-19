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

@bad-chars = "\x22", "\x2C", "\x3B", "\x5C"; #, "\x7F"..."\x80";
subtest {
    for @bad-chars -> $char {
        dies-ok { my CookieValue $cv = "Name$char"; };
    }
}, "Incorrect symbols are outside of CookieValue subset";
