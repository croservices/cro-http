use Crow::HTTP::RequestParser;
use Crow::HTTP::Request;
use Crow::TCP;
use Test;

ok Crow::HTTP::RequestParser ~~ Crow::Transform,
    'HTTP request parser is a transform';
ok Crow::HTTP::RequestParser.consumes === Crow::TCP::Message,
    'HTTP request parser consumes TCP messages';
ok Crow::HTTP::RequestParser.produces === Crow::HTTP::Request,
    'HTTP request parser produces HTTP requests';

sub test-request-to-tcp-message($req) {
    # We replace \n with \r\n in the request headers here, so the tests can
    # look pretty.
    my ($headers, $body) = $req.split(/\n\n/, 2);
    $headers .= subst("\n", "\r\n", :g);
    my $data = "$headers\r\n\r\n$body".encode('latin-1');
    return Crow::TCP::Message.new(:$data);
}

sub parses($desc, $test-request, *@checks, :$tests, *%config) {
    my $testee = Crow::HTTP::RequestParser.new(|%config);
    my $fake-in = Supplier.new;
    my $test-completed = Promise.new;
    $testee.transformer($fake-in.Supply).schedule-on($*SCHEDULER).tap:
        -> $request {
            pass $desc;
            for @checks.kv -> $i, $check {
                ok $check($request), "check {$i + 1 }";
            }
            .($request) with $tests;
            $test-completed.keep(True);
        },
        quit => {
            diag "Request parsing failed: $_";
            flunk $desc;
            skip 'Failed to parse', @checks.elems;
            $test-completed.keep(True);
        };
    start {
        $fake-in.emit(test-request-to-tcp-message($test-request));
        $fake-in.done();
    }

    await Promise.anyof($test-completed, Promise.in(10));
    unless $test-completed {
        # We only reach here if we fail emit a HTTP message.
        diag 'Request parser failed to emit a HTTP request';
        flunk $desc;
        skip 'Did not get request', @checks.elems;
    }
}

sub refuses($desc, $test-request, *@checks, *%config) {
    my $testee = Crow::HTTP::RequestParser.new(|%config);
    my $fake-in = Supplier.new;
    $testee.transformer($fake-in.Supply).tap:
        -> $request {
            diag "Request parsing unexpectedly succeeded";
            flunk $desc;
            skip 'Incorrectly parsed header', @checks.elems;
            return;
        },
        quit => -> $exception {
            pass $desc;
            for @checks.kv -> $i, $check {
                ok $check($exception), "check {$i + 1}";
            }
            return;
        };
    $fake-in.emit(test-request-to-tcp-message($test-request));

    # We only reach here if we fail emit a HTTP message (see `return`s above).
    diag 'Request parser failed to emit a HTTP request';
    flunk $desc;
    skip 'Did not get request', @checks.elems;
}

refuses 'Malformed request line - only verb', q:to/REQUEST/,
    GET

    REQUEST
    *.status == 400;

refuses 'Malformed request line - no version', q:to/REQUEST/,
    GET /

    REQUEST
    *.status == 400;

refuses 'Malformed request line - utter crap', q:to/REQUEST/,
    lol I don't even know know how to http

    REQUEST
    *.status == 400;

refuses 'Malformed HTTP version (1)', q:to/REQUEST/,
    GET / omg!!

    REQUEST
    *.status == 400;

refuses 'Malformed HTTP version (2)', q:to/REQUEST/,
    GET / FTP/1.1

    REQUEST
    *.status == 400;

refuses 'Malformed HTTP version (3)', q:to/REQUEST/,
    GET / HTTP/1

    REQUEST
    *.status == 400;

refuses 'Malformed HTTP version (4)', q:to/REQUEST/,
    GET / HTTP/10.1

    REQUEST
    *.status == 400;

refuses 'Malformed HTTP version (5)', q:to/REQUEST/,
    GET / HTTP/1.10

    REQUEST
    *.status == 400;

refuses 'Unimplemented HTTP version', q:to/REQUEST/,
    GET / HTTP/2.0

    REQUEST
    *.status == 501;

parses 'Simple GET request with no headers', q:to/REQUEST/,
    GET / HTTP/1.1

    REQUEST
    *.method eq 'GET',
    *.target eq '/',
    *.http-version eq '1.1';

parses 'Simple HEAD request with no headers', q:to/REQUEST/,
    HEAD / HTTP/1.1

    REQUEST
    *.method eq 'HEAD',
    *.target eq '/',
    *.http-version eq '1.1';

parses 'Simple POST request with no headers', q:to/REQUEST/,
    POST / HTTP/1.1

    REQUEST
    *.method eq 'POST',
    *.target eq '/',
    *.http-version eq '1.1';

parses 'Simple PUT request with no headers', q:to/REQUEST/,
    PUT / HTTP/1.1

    REQUEST
    *.method eq 'PUT',
    *.target eq '/',
    *.http-version eq '1.1';

parses 'Simple DELETE request with no headers', q:to/REQUEST/,
    DELETE / HTTP/1.1

    REQUEST
    *.method eq 'DELETE',
    *.target eq '/',
    *.http-version eq '1.1';

parses 'Simple OPTIONS request with no headers', q:to/REQUEST/,
    OPTIONS / HTTP/1.1

    REQUEST
    *.method eq 'OPTIONS',
    *.target eq '/',
    *.http-version eq '1.1';

refuses 'The TRACE method, as it is not implemented by default', q:to/REQUEST/,
    TRACE / HTTP/1.1

    REQUEST
    *.status == 501;

refuses 'The PATCH method, as it is not implemented by default', q:to/REQUEST/,
    PATCH / HTTP/1.1

    REQUEST
    *.status == 501;

parses 'The PATCH method if included in allowed-methods',
    allowed-methods => <GET PUT POST DELETE PATCH>,
    q:to/REQUEST/,
    PATCH / HTTP/1.1

    REQUEST
    *.method eq 'PATCH',
    *.target eq '/',
    *.http-version eq '1.1';

refuses 'PUT when it is not included in the allowed methods',
    allowed-methods => <GET HEAD OPTIONS>,
    q:to/REQUEST/,
    PUT / HTTP/1.1

    REQUEST
    *.status == 501;

parses 'An empty line before the request line',
    q:to/REQUEST/,

    GET / HTTP/1.1

    REQUEST
    *.method eq 'GET',
    *.target eq '/',
    *.http-version eq '1.1';

parses 'A few empty lines before the request line',
    q:to/REQUEST/,


    GET / HTTP/1.1

    REQUEST
    *.method eq 'GET',
    *.target eq '/',
    *.http-version eq '1.1';

parses 'Host header',
    q:to/REQUEST/,
    GET / HTTP/1.1
    Host: www.xkcd.com

    REQUEST
    *.method eq 'GET',
    *.target eq '/',
    *.http-version eq '1.1',
    *.headers == 1,
    *.headers[0].isa(Crow::HTTP::Header),
    *.headers[0].name eq 'Host',
    *.headers[0].value eq 'www.xkcd.com';

parses 'Host header with no whitespace',
    q:to/REQUEST/,
    GET / HTTP/1.1
    Host:www.badgerbadgerbadger.com

    REQUEST
    *.method eq 'GET',
    *.target eq '/',
    *.http-version eq '1.1',
    *.headers == 1,
    *.headers[0].isa(Crow::HTTP::Header),
    *.headers[0].name eq 'Host',
    *.headers[0].value eq 'www.badgerbadgerbadger.com';

parses 'Host header with trailing whitespace',
    q:to/REQUEST/,
    GET / HTTP/1.1
    Host:www.jnthn.net  

    REQUEST
    *.method eq 'GET',
    *.target eq '/',
    *.http-version eq '1.1',
    *.headers == 1,
    *.headers[0].isa(Crow::HTTP::Header),
    *.headers[0].name eq 'Host',
    *.headers[0].value eq 'www.jnthn.net';

parses 'Host header with tab before and after value',
    q:to/REQUEST/,
    GET / HTTP/1.1
    Host:	www.jnthn.net	

    REQUEST
    *.method eq 'GET',
    *.target eq '/',
    *.http-version eq '1.1',
    *.headers == 1,
    *.headers[0].isa(Crow::HTTP::Header),
    *.headers[0].name eq 'Host',
    *.headers[0].value eq 'www.jnthn.net';

parses 'Header with insane but actually totally legit name',
    q:to/REQUEST/,
    GET / HTTP/1.1
    !#42$%omg&'*+-.wtf^_`~|ReAlLy!!!: wow

    REQUEST
    *.method eq 'GET',
    *.target eq '/',
    *.http-version eq '1.1',
    *.headers == 1,
    *.headers[0].isa(Crow::HTTP::Header),
    *.headers[0].name eq Q/!#42$%omg&'*+-.wtf^_`~|ReAlLy!!!/,
    *.headers[0].value eq 'wow';

for <" ( ) [ ] { } @ \ / \< \> , ;> -> $nope {
	refuses "Not allowed $nope in header",
	    qq:to/REQUEST/,
	    GET / HTTP/1.1
	    um{$nope}no: ne

	    REQUEST
	    *.status == 400;
}

parses 'Field value can be any printable char including latin-1 range',
    q:to/REQUEST/,
    GET / HTTP/1.1
    X-Something: oh!"foo'<>%^&*()[]{}424242aaáâãäåæµ¥

    REQUEST
    *.method eq 'GET',
    *.target eq '/',
    *.http-version eq '1.1',
    *.headers == 1,
    *.headers[0].isa(Crow::HTTP::Header),
    *.headers[0].name eq 'X-Something',
    *.headers[0].value eq Q/oh!"foo'<>%^&*()[]{}424242aaáâãäåæµ¥/;

parses 'Field values may have whitespace in them',
    q:to/REQUEST/,
    GET / HTTP/1.1
    X-Men: this is a	sentence

    REQUEST
    *.method eq 'GET',
    *.target eq '/',
    *.http-version eq '1.1',
    *.headers == 1,
    *.headers[0].isa(Crow::HTTP::Header),
    *.headers[0].name eq 'X-Men',
    *.headers[0].value eq Q/this is a	sentence/;

parses 'Whitespace after field name ignored',
    q:to/REQUEST/,
    GET / HTTP/1.1
    X-Men: spaces inside but not		

    REQUEST
    *.method eq 'GET',
    *.target eq '/',
    *.http-version eq '1.1',
    *.headers == 1,
    *.headers[0].isa(Crow::HTTP::Header),
    *.headers[0].name eq 'X-Men',
    *.headers[0].value eq Q/spaces inside but not/;

for << \b \0 >>.kv -> $i, $cc {
    refuses "Control chars other than space/tab not allowed ($i)",
        qq:to/REQUEST/,
        GET / HTTP/1.1
        X-Something: oh{$cc}no

        REQUEST
        *.status == 400;
}

parses 'Request with multiple headers (example from RFC)',
    q:to/REQUEST/,
    GET /hello.txt HTTP/1.1
    User-Agent: curl/7.16.3 libcurl/7.16.3 OpenSSL/0.9.7l zlib/1.2.3
    Host: www.example.com
    Accept-Language: en, mi

    REQUEST
    *.method eq 'GET',
    *.target eq '/hello.txt',
    *.http-version eq '1.1',
    *.headers == 3,
    *.headers[0].isa(Crow::HTTP::Header),
    *.headers[0].name eq 'User-Agent',
    *.headers[0].value eq 'curl/7.16.3 libcurl/7.16.3 OpenSSL/0.9.7l zlib/1.2.3',
    *.headers[1].isa(Crow::HTTP::Header),
    *.headers[1].name eq 'Host',
    *.headers[1].value eq 'www.example.com',
    *.headers[2].isa(Crow::HTTP::Header),
    *.headers[2].name eq 'Accept-Language',
    *.headers[2].value eq 'en, mi';

parses 'Request path and path segments for /hello.txt',
    q:to/REQUEST/,
    GET /hello.txt HTTP/1.1

    REQUEST
    *.path eq '/hello.txt',
    *.path-segments eqv ('hello.txt',);

parses 'Request path and path segments for /oh/my/path',
    q:to/REQUEST/,
    GET /oh/my/path HTTP/1.1

    REQUEST
    *.path eq '/oh/my/path',
    *.path-segments eqv <oh my path>;

parses 'Query strings are parsed and accessible',
    q:to/REQUEST/,
    GET /foo/bar.baz?a=1&bc=2&def=lol HTTP/1.1

    REQUEST
    *.path eq '/foo/bar.baz',
    *.path-segments eqv <foo bar.baz>,
    *.query eq 'a=1&bc=2&def=lol',
    *.query-hash eqv { a => '1', bc => '2', def => 'lol' },
    *.query-value('a') eqv '1',
    *.query-value('bc') eqv '2',
    *.query-value('def') eqv 'lol';

parses 'Query strings with empty values',
    q:to/REQUEST/,
    GET /foo/bar.baz?foo&bar=&baz=42 HTTP/1.1

    REQUEST
    *.path eq '/foo/bar.baz',
    *.path-segments eqv <foo bar.baz>,
    *.query eq 'foo&bar=&baz=42',
    *.query-hash eqv { foo => '', bar => '', baz => '42' },
    *.query-value('foo') eqv '',
    *.query-value('bar') eqv '',
    *.query-value('baz') eqv '42';

parses 'Query string keys and values that are encoded',
    q:to/REQUEST/,
    GET /foo/bar.baz?a%2Fb=2%203&love=%E2%99%A5&%E2%84%A6%E2%84%A6=2omega HTTP/1.1

    REQUEST
    *.path eq '/foo/bar.baz',
    *.path-segments eqv <foo bar.baz>,
    *.query eq 'a%2Fb=2%203&love=%E2%99%A5&%E2%84%A6%E2%84%A6=2omega',
    *.query-hash eqv { 'a/b' => '2 3', love => '♥', ΩΩ => '2omega' },
    *.query-value('a/b') eqv '2 3',
    *.query-value('love') eqv '♥',
    *.query-value('ΩΩ') eqv '2omega';

parses 'Query strings with multiple values for the same key',
    q:to/REQUEST/,
    GET /foo?x=foo&y=bar&y=baz&x=%E2%99%A5&z=one HTTP/1.1

    REQUEST
    *.path eq '/foo',
    *.path-segments eqv ('foo',),
    *.query eq 'x=foo&y=bar&y=baz&x=%E2%99%A5&z=one',
    *.query-hash eqv {
        x => Crow::HTTP::MultiValue.new('foo', '♥'),
        y => Crow::HTTP::MultiValue.new('bar', 'baz'),
        z => 'one'
    },
    *.query-value('x') eqv Crow::HTTP::MultiValue.new('foo', '♥'),
    *.query-value('x').Str eqv 'foo,♥',
    *.query-value('y') eqv Crow::HTTP::MultiValue.new('bar', 'baz'),
    *.query-value('y').Str eqv 'bar,baz',
    *.query-value('z') eqv 'one';


parses 'Request with body, length specified by content-length',
    q:to/REQUEST/,
    POST /bar HTTP/1.1
    Content-Type: text/plain
    Content-Length: 51

    abcdefghijabcdefghijabcdefghijabcdefghijabcdefghij
    REQUEST
    *.method eq 'POST',
    *.target eq '/bar',
    *.body-text.result eq "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghij\n";

parses 'Request with body, sent with chunked encoding',
    q:b:to/REQUEST/.chop,
    POST /bar HTTP/1.1
    Content-Type: text/plain
    Transfer-encoding: chunked

    13\r\nThe first response
    \r\n20\r\nThe second
    with a newline in it
    \r\n0\r\n\r\n
    REQUEST
    *.method eq 'POST',
    *.target eq '/bar',
    *.body-text.result eq "The first response\nThe second\nwith a newline in it\n";

parses 'A text/whatever request with body',
    q:to/REQUEST/,
    POST /bar HTTP/1.1
    Content-Type: text/whatever
    Content-Length: 51

    abcdefghijabcdefghijabcdefghijabcdefghijabcdefghij
    REQUEST
    tests => {
        my $body = .body.result;
        isa-ok $body, Str, 'text/whatever gives string body';
        is $body, "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghij\n",
            'Body contains the correct value';
    };

parses 'A unknown/foo request with body',
    q:to/REQUEST/,
    POST /bar HTTP/1.1
    Content-type: unknown/foo
    Content-Length: 11

    abcdefghij
    REQUEST
    tests => {
        my $body = .body.result;
        ok $body ~~ Blob, 'unknown/foo .body gives Blob';
        is $body.decode('ascii'), "abcdefghij\n", 'Blob has correct content';
    };

parses 'Basic case of application/x-www-form-urlencoded',
    q:to/REQUEST/.chop,
    POST /bar HTTP/1.1
    Content-type: application/x-www-form-urlencoded
    Content-length: 33

    rooms=2&balcony=true&area=Praha+3
    REQUEST
    tests => {
        my $body = .body.result;
        is-deeply $body.pairs.list, (rooms => '2', balcony => 'true', area => 'Praha 3'),
            '.pairs returns ordered pairs from the decoded body';
        is-deeply $body.list, (rooms => '2', balcony => 'true', area => 'Praha 3'),
            '.list returns ordered pairs from the decoded body';
        is-deeply $body.hash, {rooms => '2', balcony => 'true', area => 'Praha 3'},
            '.hash returns hash of the decoded body';
        is $body<rooms>, '2', 'Can index associatively (1)';
        is $body<balcony>, 'true', 'Can index associatively (2)';
        is $body<area>, 'Praha 3', 'Can index associatively (3)';
        is $body<rooms>:exists, True, 'Can index associatively with :exists (1)';
        is $body<balcony>:exists, True, 'Can index associatively with :exists (2)';
        is $body<area>:exists, True, 'Can index associatively with :exists (3)';
    };

parses 'Multiple entries with same name in application/x-www-form-urlencoded',
    q:to/REQUEST/.chop,
    POST /bar HTTP/1.1
    Content-type: application/x-www-form-urlencoded
    Content-length: 23

    a=1&b=2&a=3&a=4&b=5&c=6
    REQUEST
    tests => {
        my $body = .body.result;
        is-deeply $body.pairs.list, (a => '1', b => '2', a => '3', a => '4', b => '5', c => '6'),
            '.pairs returns ordered pairs, with multiple values in place';
        is-deeply $body.list, (a => '1', b => '2', a => '3', a => '4', b => '5', c => '6'),
            '.list returns ordered pairs, with muliplte values in place';

        my %hash = $body.hash;
        is %hash.elems, 3, '.hash gives back Hash with 3 elements';
        isa-ok %hash<a>, Crow::HTTP::MultiValue, 'Get back a HTTP multi-value (1)';
        isa-ok %hash<b>, Crow::HTTP::MultiValue, 'Get back a HTTP multi-value (2)';
        is %hash<a>, '1,3,4', 'Stringifying multi-value is correct (1)';
        is %hash<b>, '2,5', 'Stringifying multi-value is correct (2)';
        is-deeply %hash<a>[*], ('1', '3', '4'), 'Indexing multi-value is correct (1)';
        is-deeply %hash<b>[*], ('2', '5'), 'Indexing multi-value is correct (2)';
        isa-ok %hash<c>, Str, 'When only one value with the name, get back a Str';
        is %hash<c>, '6', 'Value is correct';

        isa-ok $body<a>, Crow::HTTP::MultiValue, 'Hash-indexing body gives HTTP multi-value (1)';
        isa-ok $body<b>, Crow::HTTP::MultiValue, 'Hash-indexing body gives HTTP multi-value (2)';
        isa-ok $body<c>, Str, 'Except when only one value for the name, then it is Str';
    };

parses 'Basic %-encoded things in an application/x-www-form-urlencoded',
    q:to/REQUEST/.chop,
    POST /bar HTTP/1.1
    Content-type: application/x-www-form-urlencoded
    Content-length: 43

    x=A%2BC&y=100%25AA%21&A%2BC=1&100%25AA%21=2
    REQUEST
    tests => {
        my $body = .body.result;
        is-deeply $body.list, (x => 'A+C', y => '100%AA!', 'A+C' => '1', '100%AA!' => '2'),
            '%-encoded values in ASCII range handled correctly';
    };

parses '%-encoded non-ASCII is utf-8 by default in  application/x-www-form-urlencoded',
    q:to/REQUEST/.chop,
    POST /bar HTTP/1.1
    Content-type: application/x-www-form-urlencoded
    Content-length: 30

    x=%C3%80b&%E3%82%A2%E3%82%A2=1
    REQUEST
    tests => {
        my $body = .body.result;
        is-deeply $body.list, (
                x => "\c[LATIN CAPITAL LETTER A WITH GRAVE]b",
                "\c[KATAKANA LETTER A]\c[KATAKANA LETTER A]" => '1'
            ),
            '%-encoded values default to UTF-8 decoding';
    };

# XXX Test these security checks (allow configuration of them):
#
# HTTP does not place a predefined limit on the length of a
# request-line, as described in Section 2.5.  A server that receives a
# method longer than any that it implements SHOULD respond with a 501
# (Not Implemented) status code.  A server that receives a
# request-target longer than any URI it wishes to parse MUST respond
# with a 414 (URI Too Long) status code (see Section 6.5.12 of
# [RFC7231]).
#
# Various ad hoc limitations on request-line length are found in
# practice.  It is RECOMMENDED that all HTTP senders and recipients
# support, at a minimum, request-line lengths of 8000 octets.

done-testing;
