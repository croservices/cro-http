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
    my ($headers, $body) = $req.split(/<!before ^>\n\n/);
    $headers .= subst("\n", "\r\n", :g);
    my $data = "$headers\r\n\r\n$body".encode('latin-1');
    return Crow::TCP::Message.new(:$data);
}

sub parses($desc, $test-request, *@checks, *%config) {
    my $testee = Crow::HTTP::RequestParser.new(|%config);
    my $fake-in = Supplier.new;
    $testee.transformer($fake-in.Supply).tap:
        -> $request {
            pass $desc;
            for @checks.kv -> $i, $check {
                ok $check($request), "check {$i + 1 }";
            }
            return;
        },
        quit => {
            diag "Request parsing failed: $_";
            flunk $desc;
            skip 'Failed to parse', @checks.elems;
            return;
        };
    $fake-in.emit(test-request-to-tcp-message($test-request));

    # We only reach here if we fail emit a HTTP message (see `return`s above).
    diag 'Request parser failed to emit a HTTP request';
    flunk $desc;
    skip 'Did not get request', @checks.elems;
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
