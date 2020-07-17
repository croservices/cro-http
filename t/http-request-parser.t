use Cro::BodyParserSelector;
use Cro::HTTP::BodyParsers;
use Cro::HTTP::RequestParser;
use Cro::HTTP::Request;
use Cro::TCP;
use Test;

ok Cro::HTTP::RequestParser ~~ Cro::Transform,
    'HTTP request parser is a transform';
ok Cro::HTTP::RequestParser.consumes === Cro::TCP::Message,
    'HTTP request parser consumes TCP messages';
ok Cro::HTTP::RequestParser.produces === Cro::HTTP::Request,
    'HTTP request parser produces HTTP requests';

sub test-request-to-tcp-message($req, :$body-crlf, :$body-blob) {
    # We replace \n with \r\n in the request headers here, so the tests can
    # look pretty.
    my ($headers, $body) = $req.split(/\n\n/, 2);
    $headers .= subst("\n", "\r\n", :g);
    $body .= subst("\n", "\r\n", :g) if $body-crlf;
    my $data = "$headers\r\n\r\n$body".encode('latin-1');
    $data ~= $body-blob if $body-blob;
    return Cro::TCP::Message.new(:$data);
}

sub parses($desc, $test-request, *@checks, :$tests, :$body-crlf, :$body-blob, *%config) {
    my $testee = Cro::HTTP::RequestParser.new(|%config);
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
        my $req-blob = test-request-to-tcp-message($test-request, :$body-crlf, :$body-blob);
        $fake-in.emit($req-blob);
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
    my $testee = Cro::HTTP::RequestParser.new(|%config);
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

parses 'Simple PATCH request with no headers', q:to/REQUEST/,
    PATCH / HTTP/1.1

    REQUEST
    *.method eq 'PATCH',
    *.target eq '/',
    *.http-version eq '1.1';

refuses 'The TRACE method, as it is not implemented by default', q:to/REQUEST/,
    TRACE / HTTP/1.1

    REQUEST
    *.status == 501;

parses 'The TRACE method if included in allowed-methods',
    allowed-methods => <GET PUT POST DELETE TRACE>,
    q:to/REQUEST/,
    TRACE / HTTP/1.1

    REQUEST
    *.method eq 'TRACE',
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
    *.headers[0].isa(Cro::HTTP::Header),
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
    *.headers[0].isa(Cro::HTTP::Header),
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
    *.headers[0].isa(Cro::HTTP::Header),
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
    *.headers[0].isa(Cro::HTTP::Header),
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
    *.headers[0].isa(Cro::HTTP::Header),
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

parses 'Header with empty field',
    q:to/REQUEST/,
    GET / HTTP/1.1
    myproto: 

    REQUEST
    *.method eq 'GET',
    *.target eq '/',
    *.http-version eq '1.1',
    *.headers == 1,
    *.headers[0].isa(Cro::HTTP::Header),
    *.headers[0].name eq 'myproto',
    *.headers[0].value eq '';

parses 'Field value can be any printable char including latin-1 range',
    q:to/REQUEST/,
    GET / HTTP/1.1
    X-Something: oh!"foo'<>%^&*()[]{}424242aaáâãäåæµ¥

    REQUEST
    *.method eq 'GET',
    *.target eq '/',
    *.http-version eq '1.1',
    *.headers == 1,
    *.headers[0].isa(Cro::HTTP::Header),
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
    *.headers[0].isa(Cro::HTTP::Header),
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
    *.headers[0].isa(Cro::HTTP::Header),
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
    *.headers[0].isa(Cro::HTTP::Header),
    *.headers[0].name eq 'User-Agent',
    *.headers[0].value eq 'curl/7.16.3 libcurl/7.16.3 OpenSSL/0.9.7l zlib/1.2.3',
    *.headers[1].isa(Cro::HTTP::Header),
    *.headers[1].name eq 'Host',
    *.headers[1].value eq 'www.example.com',
    *.headers[2].isa(Cro::HTTP::Header),
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
        x => Cro::HTTP::MultiValue.new('foo', '♥'),
        y => Cro::HTTP::MultiValue.new('bar', 'baz'),
        z => 'one'
    },
    *.query-value('x') eqv Cro::HTTP::MultiValue.new('foo', '♥'),
    *.query-value('x').Str eqv 'foo,♥',
    *.query-value('y') eqv Cro::HTTP::MultiValue.new('bar', 'baz'),
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
        isa-ok %hash<a>, Cro::HTTP::MultiValue, 'Get back a HTTP multi-value (1)';
        isa-ok %hash<b>, Cro::HTTP::MultiValue, 'Get back a HTTP multi-value (2)';
        is %hash<a>, '1,3,4', 'Stringifying multi-value is correct (1)';
        is %hash<b>, '2,5', 'Stringifying multi-value is correct (2)';
        is-deeply %hash<a>[*], ('1', '3', '4'), 'Indexing multi-value is correct (1)';
        is-deeply %hash<b>[*], ('2', '5'), 'Indexing multi-value is correct (2)';
        isa-ok %hash<c>, Str, 'When only one value with the name, get back a Str';
        is %hash<c>, '6', 'Value is correct';

        isa-ok $body<a>, Cro::HTTP::MultiValue, 'Hash-indexing body gives HTTP multi-value (1)';
        isa-ok $body<b>, Cro::HTTP::MultiValue, 'Hash-indexing body gives HTTP multi-value (2)';
        isa-ok $body<c>, Str, 'Except when only one value for the name, then it is Str';
    };

parses 'Charset present in content-type header field after application/x-www-form-urlencoded',
    q:to/REQUEST/.chop,
    POST /bar HTTP/1.1
    Content-type: application/x-www-form-urlencoded; charset=UTF-8
    Content-length: 7

    a=1&b=2
    REQUEST
    tests => {
        my $body = .body.result;
        is-deeply $body.list, (a => '1', b => '2'),
            'WWWUrlEncode prasers works correct with charset in content-type';
    };

parses 'WWWFormUrlEncoded with empty body',
    q:to/REQUEST/.chop,
    POST /bar HTTP/1.1
    Content-length: 0

    
    REQUEST
    tests => {
        my $body = .body.result;
        is-deeply $body.list, (),
            'test `with message.content-type` returns Boolean';
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

parses 'Can pick default encoding for application/x-www-form-urlencoded',
    q:to/REQUEST/.chop,
    POST /bar HTTP/1.1
    Content-type: application/x-www-form-urlencoded
    Content-length: 17

    x=%C0%C1&%D5%D6=1
    REQUEST
    tests => {
        .body-parser-selector = Cro::BodyParserSelector::List.new(:parsers[
            Cro::HTTP::BodyParser::WWWFormUrlEncoded.new(
                default-encoding => 'latin-1'
            )
        ]);
        my $body = .body.result;
        is-deeply $body.keys, <x ÕÖ>;
        is-deeply $body.values, ('ÀÁ', '1');
        is-deeply $body.list, (x => "ÀÁ", "ÕÖ" => '1'),
            '%-encoded values handled correctly when default set to latin-1';
        is $body.gist, 'Cro::HTTP::Body::WWWFormUrlEncoded(x=｢ÀÁ｣,ÕÖ=｢1｣)';
        is $body.perl, 'Cro::HTTP::Body::WWWFormUrlEncoded(:pairs[(:x("ÀÁ"), :ÕÖ("1"))])';
    };

parses 'Respects encoding set by _charset_ in application/x-www-form-urlencoded',
    q:to/REQUEST/.chop,
    POST /bar HTTP/1.1
    Content-type: application/x-www-form-urlencoded
    Content-length: 35

    x=%C0%C1&%D5%D6=1&_charset_=latin-1
    REQUEST
    tests => {
        my $body = .body.result;
        is-deeply $body.list, (x => "ÀÁ", "ÕÖ" => '1', '_charset_' => 'latin-1'),
            '%-encoded values decoded as latin-1 as set in _charset_';
    };

parses 'A _charset_ in application/x-www-form-urlencoded overrides configured default',
    q:to/REQUEST/.chop,
    POST /bar HTTP/1.1
    Content-type: application/x-www-form-urlencoded
    Content-length: 46

    x=%C3%80b&%E3%82%A2%E3%82%A2=1&_charset_=utf-8
    REQUEST
    tests => {
        .body-parser-selector = Cro::BodyParserSelector::List.new(:parsers[
            Cro::HTTP::BodyParser::WWWFormUrlEncoded.new(
                default-encoding => 'latin-1'
            )
        ]);
        my $body = .body.result;
        is-deeply $body.list, (
                x => "\c[LATIN CAPITAL LETTER A WITH GRAVE]b",
                "\c[KATAKANA LETTER A]\c[KATAKANA LETTER A]" => '1',
                '_charset_' => 'utf-8'
            ),
            'Values were decoded as utf-8, not latin-1 default, due to _charset_';
    };

parses 'Simple multipart/form-data',
    q:to/REQUEST/, :body-crlf,
    POST /bar HTTP/1.1
    Content-type: multipart/form-data; boundary="---------------------------20445073621891389863245745954"
    Content-length: 307

    -----------------------------20445073621891389863245745954
    Content-Disposition: form-data; name="a"

    3555555555555555551
    -----------------------------20445073621891389863245745954
    Content-Disposition: form-data; name="b"

    53399393939222
    -----------------------------20445073621891389863245745954--
    REQUEST
    tests => {
        my $body = .body.result;
        my @parts = $body.parts;
        is @parts[0].headers.elems, 1, 'First part has 1 header';
        is @parts[0].headers[0].name, 'Content-Disposition', 'First part header name correct';
        is @parts[0].headers[0].value, 'form-data; name="a"', 'First part header value correct';
        ok @parts[0].content-type ~~ Cro::MediaType,
            'First part has a content-type that is a Cro::MediaType';
        is @parts[0].content-type.type, 'text', 'First part has default text type';
        is @parts[0].content-type.subtype, 'plain', 'First part has default plain subtype';
        is @parts[0].name, 'a', 'First part has correct field name';
        is-deeply @parts[0].body-blob, '3555555555555555551'.encode('ascii'),
            'First part has correct body blob';
        is @parts[0].body-text, '3555555555555555551', 'First part has correct body text';
        is-deeply @parts[0].body, '3555555555555555551', 'First part has correct body';
        is @parts[1].headers.elems, 1, 'Second part has 1 header';
        is @parts[1].headers[0].name, 'Content-Disposition', 'Second part header name correct';
        is @parts[1].headers[0].value, 'form-data; name="b"', 'Second part header value correct';
        is @parts[1].name, 'b', 'Second part has correct field name';
        ok @parts[1].content-type ~~ Cro::MediaType,
            'Second part has a content-type that is a Cro::MediaType';
        is @parts[1].content-type.type, 'text', 'Second part has default text type';
        is @parts[1].content-type.subtype, 'plain', 'Second part has default plain subtype';
        is-deeply @parts[1].body-blob, '53399393939222'.encode('ascii'),
            'Second part has correct body blob';
        is @parts[1].body-text, '53399393939222', 'Second part has correct body text';
        is-deeply @parts[1].body-text, '53399393939222', 'Second part has correct body';
    }

parses 'A multipart/form-data with a file upload',
    q:to/REQUEST/,
    POST /bar HTTP/1.1
    Content-type: multipart/form-data; boundary="---------------------------20544114801586259283507660231"
    Content-length: 405

    REQUEST
    body-blob => Buf.new(45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,
        45,45,45,45,45,45,45,45,50,48,53,52,52,49,49,52,56,48,49,53,56,54,50,53,57,50,56,
        51,53,48,55,54,54,48,50,51,49,13,10,67,111,110,116,101,110,116,45,68,105,115,112,
        111,115,105,116,105,111,110,58,32,102,111,114,109,45,100,97,116,97,59,32,110,97,
        109,101,61,34,116,105,116,108,101,34,13,10,13,10,73,32,99,97,110,32,115,101,101,
        32,114,105,103,104,116,32,116,104,114,111,117,103,104,32,116,104,105,115,13,10,45,
        45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,
        45,50,48,53,52,52,49,49,52,56,48,49,53,56,54,50,53,57,50,56,51,53,48,55,54,54,48,
        50,51,49,13,10,67,111,110,116,101,110,116,45,68,105,115,112,111,115,105,116,105,
        111,110,58,32,102,111,114,109,45,100,97,116,97,59,32,110,97,109,101,61,34,112,104,
        111,116,111,34,59,32,102,105,108,101,110,97,109,101,61,34,84,114,97,110,115,112,
        97,114,101,110,116,46,103,105,102,34,13,10,67,111,110,116,101,110,116,45,84,121,
        112,101,58,32,105,109,97,103,101,47,103,105,102,13,10,13,10,71,73,70,56,57,97,1,0,
        1,0,128,0,0,0,0,0,255,255,255,33,249,4,1,0,0,0,0,44,0,0,0,0,1,0,1,0,0,2,1,68,0,59,
        13,10,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,
        45,45,45,45,50,48,53,52,52,49,49,52,56,48,49,53,56,54,50,53,57,50,56,51,53,48,55,
        54,54,48,50,51,49,45,45,13,10),
    tests => {
        my $body = .body.result;
        my @parts = $body.parts;
        is @parts.elems, 2, 'Have 2 parts';

        is @parts[0].headers.elems, 1, 'First part has 1 header';
        is @parts[0].headers[0].name, 'Content-Disposition', 'First part header name correct';
        is @parts[0].headers[0].value, 'form-data; name="title"', 'First part header value correct';
        ok @parts[0].content-type ~~ Cro::MediaType,
            'First part has a content-type that is a Cro::MediaType';
        is @parts[0].content-type.type, 'text', 'First part has default text type';
        is @parts[0].content-type.subtype, 'plain', 'First part has default plain subtype';
        is @parts[0].name, 'title', 'First part has correct field name';
        ok !defined(@parts[0].filename), 'First part has no filename';
        is @parts[0].body-text, 'I can see right through this', 'First part has correct body text';
        is-deeply @parts[0].body, 'I can see right through this', 'First part has correct body';

        is @parts[1].headers.elems, 2, 'Second part has 2 headers';
        is @parts[1].headers[0].name, 'Content-Disposition',
            'First header name correct';
        is @parts[1].headers[0].value, 'form-data; name="photo"; filename="Transparent.gif"',
            'First header value correct';
        is @parts[1].headers[1].name, 'Content-Type',
            'Second header name correct';
        is @parts[1].headers[1].value, 'image/gif',
            'Second header value correct';
        ok @parts[1].content-type ~~ Cro::MediaType,
            'Second part has a content-type that is a Cro::MediaType';
        is @parts[1].content-type.type, 'image', 'Second part has image media type';
        is @parts[1].content-type.subtype, 'gif', 'Second part has gif media subtype';
        is @parts[1].name, 'photo', 'Second part has correct field name';
        is @parts[1].filename, 'Transparent.gif', 'Second part has correct filename';
        is-deeply @parts[1].body-blob,
            Blob[uint8].new(71,73,70,56,57,97,1,0,1,0,128,0,0,0,0,0,255,255,255,33,249,4,1,
                0,0,0,0,44,0,0,0,0,1,0,1,0,0,2,1,68,0,59),
            'Second part has correct body blob';
        is-deeply @parts[1].body,
            Blob[uint8].new(71,73,70,56,57,97,1,0,1,0,128,0,0,0,0,0,255,255,255,33,249,4,1,
                0,0,0,0,44,0,0,0,0,1,0,1,0,0,2,1,68,0,59),
            'Second part has correct body';
    };

parses 'An application/json request decodes JSON body',
    q:to/REQUEST/,
    POST /bar HTTP/1.1
    Content-type: application/json
    Content-Length: 25

    { "foo": [ "bar", 42 ] }
    REQUEST
    tests => {
        my $body = .body.result;
        ok $body ~~ Hash, '.body of application/json with object gives Hash';
        is-deeply $body, ${ foo => [ "bar", 42 ] }, 'JSON was correctly decoded';
    };

parses 'An media type with the +json suffix decodes JSON body',
    q:to/REQUEST/,
    POST /bar HTTP/1.1
    Content-type: application/vnd.my-org+json
    Content-Length: 25

    { "foo": [ "baz", 46 ] }
    REQUEST
    tests => {
        my $body = .body.result;
        ok $body ~~ Hash, '.body of application/vnd.my-org+json with object gives Hash';
        is-deeply $body, ${ foo => [ "baz", 46 ] }, 'JSON was correctly decoded';
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

sub messages($desc, $mess1, $mess2, @checks1, @checks2) {
    my $parser = Cro::HTTP::RequestParser.new;
    my $fake-in = Supplier.new;
    my Int $counter = 0;
    my $test-completed = Promise.new;
    $parser.transformer($fake-in.Supply).tap: -> $request {
        my $body = $request.body-text.result;
        if $counter == 0 {
            for @checks1.kv -> $i, $check {
                ok $check($body), "check first {$i + 1}";
            }

        } else {
            for @checks2.kv -> $i, $check {
                ok $check($body), "check second {$i + 1}";
            }
        }
        $counter++;
        $test-completed.keep(True) if $counter == 2;
    };

    start {
        my $req-blob1 = test-request-to-tcp-message($mess1);
        my $req-blob2 = test-request-to-tcp-message($mess2) if $mess2;
        $fake-in.emit($req-blob1);
        $fake-in.emit($req-blob2) if $mess2;
        $fake-in.done();
    }

    await Promise.anyof($test-completed, Promise.in(10));
    if $test-completed {
        pass $desc;
    } else {
        flunk $desc;
    }
}

messages 'Two separate packages are parsed', q:to/REQUEST/,
    POST /bar HTTP/1.1
    Content-Type: text/plain
    Content-Length: 22

    Fields, Flowers, Rails
    POST /bar HTTP/1.1
    Content-Type: text/plain
    Content-Length: 19

    Gear Of Despondency
    REQUEST
    q:to/REQUEST/,
    REQUEST
    ([* eq 'Fields, Flowers, Rails']),
    ([* eq 'Gear Of Despondency']);

messages 'Two separate packages are parsed, RequestLine in the first', q:to/REQUEST/,
    POST /bar HTTP/1.1
    Content-Type: text/plain
    Content-Length: 22

    Fields, Flowers, Rails
    POST /bar HTTP/1.1
    REQUEST
    q:to/REQUEST/,
    Content-Type: text/plain
    Content-Length: 19

    Gear Of Despondency
    REQUEST
    ([* eq 'Fields, Flowers, Rails']),
    ([* eq 'Gear Of Despondency']);

messages 'Two separate packages are parsed, RequestLine and part of header in the first', q:to/REQUEST/,
    POST /bar HTTP/1.1
    Content-Type: text/plain
    Content-Length: 22

    Fields, Flowers, Rails
    POST /bar HTTP/1.1
    Content-Type: text/plain
    REQUEST
    q:to/REQUEST/,
    Content-Length: 19

    Gear Of Despondency
    REQUEST
    ([* eq 'Fields, Flowers, Rails']),
    ([* eq 'Gear Of Despondency']);

done-testing;
