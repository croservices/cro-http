use Crow::Uri::HTTP;
use Test;

sub parses-request-target($desc, $target, *@checks) {
    with try Crow::Uri::HTTP.parse-request-target($target) -> $parsed {
        pass $desc;
        for @checks.kv -> $i, $check {
            ok $check($parsed), "Check {$i + 1}";
        }
    }
    else {
        diag "Request target parsing failed: $!";
        flunk $desc;
        skip 'Failed to parse', @checks.elems;
    }
}

sub refuses-request-target($desc, $target) {
    with try Crow::Uri::HTTP.parse-request-target($target) {
        diag "Incorrectly parsed $target";
        flunk $desc;
    }
    elsif $! ~~ X::Crow::Uri::ParseError {
        pass $desc;
    }
    else {
        diag "Wrong exception type ($!.^name())";
        flunk $desc;
    }
}

parses-request-target 'A single / request target',
    '/',
    !*.scheme.defined,
    !*.authority.defined,
    *.path eq '/',
    *.path-segments eqv ("",),
    !*.query.defined,
    !*.fragment.defined;

parses-request-target 'A single /foo/bar.html request target',
    '/foo/bar.html',
    *.path eq '/foo/bar.html',
    *.path-segments eqv <foo bar.html>,
    !*.query.defined;

done-testing;
