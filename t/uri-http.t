use Cro::Uri::HTTP;
use Test;

sub parses-request-target($desc, $target, *@checks) {
    with try Cro::Uri::HTTP.parse-request-target($target) -> $parsed {
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
    with try Cro::Uri::HTTP.parse-request-target($target) {
        diag "Incorrectly parsed $target";
        flunk $desc;
    }
    elsif $! ~~ X::Cro::Uri::ParseError {
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

subtest 'Basic query string additions as pair arguemnts' => {
    given Cro::Uri::HTTP.parse('http://foo.com/foo/bar').add-query('foo' => 42, 'bar' => 'baz') {
        is .path, '/foo/bar', 'Path was retained correctly';
        is .query, 'foo=42&bar=baz', 'Query string correctly appended';
    }
}

subtest 'Basic query string additions as named arguments' => {
    given Cro::Uri::HTTP.parse('http://foo.com/foo/bar').add-query(foo => 42, bar => 'baz') {
        is .path, '/foo/bar', 'Path was retained correctly';
        ok .query eq 'foo=42&bar=baz' | 'bar=baz&foo=42', 'Query string correctly appended';
    }
}

subtest 'Basic query string additions retain what was originally there' => {
    given Cro::Uri::HTTP.parse('http://foo.com/foo/bar?x=99').add-query('foo' => 42, 'bar' => 'baz') {
        is .path, '/foo/bar', 'Path was retained correctly';
        is .query, 'x=99&foo=42&bar=baz', 'Existing query string values were retained';
    }
}

subtest 'Query string keys and values are encoded' => {
    given Cro::Uri::HTTP.parse('http://foo.com/foo/bar').add-query('a$?b!/3\45:6' => 'přiběh') {
        is .path, '/foo/bar', 'Path was retained correctly';
        is .query, 'a%24%3Fb%21%2F3%5C45%3A6=p%C5%99ib%C4%9Bh', 'Correct encoding';
    }
}

done-testing;
