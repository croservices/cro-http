use Crow::HTTP::ResponseParser;
use Crow::HTTP::Response;
use Crow::TCP;
use Test;

ok Crow::HTTP::ResponseParser ~~ Crow::Transform,
    'HTTP response parser is a transform';
ok Crow::HTTP::ResponseParser.consumes === Crow::TCP::Message,
    'HTTP response parser consumes TCP messages';
ok Crow::HTTP::ResponseParser.produces === Crow::HTTP::Response,
    'HTTP respose parser produces HTTP responses';

sub test-response-to-tcp-message($res, :$body-blob) {
    # We replace \n with \r\n in the response headers here, so the tests can
    # look pretty.
    my ($headers, $body) = $res.split(/\n\n/, 2);
    $headers .= subst("\n", "\r\n", :g);
    my $data = "$headers\r\n\r\n".encode('latin-1') ~ $body.encode('utf-8');
    $data ~= $body-blob if $body-blob;
    return Crow::TCP::Message.new(:$data);
}

sub parses($desc, $test-response, :$body-blob, *@checks, *%config) {
    my $testee = Crow::HTTP::ResponseParser.new(|%config);
    my $fake-in = Supplier.new;
    my $test-completed = Promise.new;
    $testee.transformer($fake-in.Supply).schedule-on($*SCHEDULER).tap:
        -> $response {
            pass $desc;
            for @checks.kv -> $i, $check {
                ok $check($response), "check {$i + 1 }";
            }
            $test-completed.keep(True);
        },
        quit => {
            diag "Response parsing failed: $_";
            flunk $desc;
            skip 'Failed to parse', @checks.elems;
            $test-completed.keep(True);
        };
    start {
        $fake-in.emit(test-response-to-tcp-message($test-response, :$body-blob));
        $fake-in.done();
    }

    await Promise.anyof($test-completed, Promise.in(10));
    unless $test-completed {
        # We only reach here if we fail emit a HTTP message.
        diag 'Response parser failed to emit a HTTP response';
        flunk $desc;
        skip 'Did not get response', @checks.elems;
    }
}

sub refuses($desc, $test-response, *%config) {
    my $testee = Crow::HTTP::ResponseParser.new(|%config);
    my $fake-in = Supplier.new;
    $testee.transformer($fake-in.Supply).tap:
        -> $response {
            diag "Response parsing unexpectedly succeeded";
            flunk $desc;
            return;
        },
        quit => -> $exception {
            pass $desc;
            return;
        };
    $fake-in.emit(test-response-to-tcp-message($test-response));

    # We only reach here if we fail emit a HTTP message (see `return`s above).
    diag 'Respose parser failed to emit a HTTP response';
    flunk $desc;
}

parses 'Simple 204 no content response', q:to/RESPONSE/,
    HTTP/1.1 204 No content

    RESPONSE
    *.http-version eq '1.1',
    *.status == 204;

refuses 'Malformed status line - only version', q:to/RESPONSE/;
    HTTP/1.1

    RESPONSE

refuses 'Malformed status line - missing space after status code', q:to/RESPONSE/;
    HTTP/1.1 204

    RESPONSE

parses 'Simple 204 no content response with empty reason', q:to/RESPONSE/,
    HTTP/1.1 204 

    RESPONSE
    *.http-version eq '1.1',
    *.status == 204;

refuses 'Malformed status line - code is only one digit', q:to/RESPONSE/;
    HTTP/1.1 2 No content

    RESPONSE

refuses 'Malformed status line - code is only two digits', q:to/RESPONSE/;
    HTTP/1.1 20 No content

    RESPONSE

refuses 'Malformed status line - code is four digits', q:to/RESPONSE/;
    HTTP/1.1 2004 No content

    RESPONSE

parses 'Minor version other than 1 OK (1)', q:to/RESPONSE/,
    HTTP/1.0 204 No content

    RESPONSE
    *.http-version eq '1.0',
    *.status == 204;

parses 'Minor version other than 1 OK (2)', q:to/RESPONSE/,
    HTTP/1.2 204 No content

    RESPONSE
    *.http-version eq '1.2',
    *.status == 204;

refuses 'Invalid major version (1)', q:to/RESPONSE/;
    HTTP/2.1 204 No content

    RESPONSE

refuses 'Invalid major version (2)', q:to/RESPONSE/;
    HTTP/0.1 204 No content

    RESPONSE

refuses 'Double-digit minor version', q:to/RESPONSE/;
    HTTP/1.11 204 No content

    RESPONSE

parses 'All non-controls allowed in reason', q:to/RESPONSE/,
    HTTP/1.1 204 WOW! V3RY 'C@@L"! Æãåñ/

    RESPONSE
    *.http-version eq '1.1',
    *.status == 204;

for << \b \f \0 >>.kv -> $i, $cc {
    refuses "Control chars in reason ($i)", qq:to/RESPONSE/;
        HTTP/1.1 204 Can't $cc here

        RESPONSE
}

parses 'Single simple header', q:to/RESPONSE/,
    HTTP/1.1 200 OK
    Server: Apache

    RESPONSE
    *.http-version eq '1.1',
    *.status == 200,
    *.headers == 1,
    *.headers[0].name eq 'Server',
    *.headers[0].value eq 'Apache';

parses 'Single header without whitespace', q:to/RESPONSE/,
    HTTP/1.1 200 OK
    Server:Apache

    RESPONSE
    *.http-version eq '1.1',
    *.status == 200,
    *.headers == 1,
    *.headers[0].name eq 'Server',
    *.headers[0].value eq 'Apache';

parses 'Single header with trailing whitespace', q:to/RESPONSE/,
    HTTP/1.1 200 OK
    Server: Apache  

    RESPONSE
    *.http-version eq '1.1',
    *.status == 200,
    *.headers == 1,
    *.headers[0].name eq 'Server',
    *.headers[0].value eq 'Apache';

parses 'Host header with tab before and after value', q:to/RESPONSE/,
    HTTP/1.1 200 OK
    Server:	Apache	

    RESPONSE
    *.http-version eq '1.1',
    *.status == 200,
    *.headers == 1,
    *.headers[0].name eq 'Server',
    *.headers[0].value eq 'Apache';

parses 'Header with insane but actually totally legit name', q:to/RESPONSE/,
    HTTP/1.1 200 OK
    !#42$%omg&'*+-.wtf^_`~|ReAlLy!!!: wow

    RESPONSE
    *.http-version eq '1.1',
    *.status == 200,
    *.headers == 1,
    *.headers[0].name eq Q/!#42$%omg&'*+-.wtf^_`~|ReAlLy!!!/,
    *.headers[0].value eq 'wow';

for <" ( ) [ ] { } @ \ / \< \> , ;> -> $nope {
	refuses "Not allowed $nope in header name",
	    qq:to/RESPONSE/;
	    HTTP/1.1 200 OK
	    um{$nope}no: ne

	    RESPONSE
}

parses 'Header field value can be any printable char including latin-1 range',
    q:to/RESPONSE/,
    HTTP/1.1 200 OK
    X-Something: oh!"foo'<>%^&*()[]{}424242aaáâãäåæµ¥

    RESPONSE
    *.status == 200,
    *.http-version eq '1.1',
    *.headers == 1,
    *.headers[0].isa(Crow::HTTP::Header),
    *.headers[0].name eq 'X-Something',
    *.headers[0].value eq Q/oh!"foo'<>%^&*()[]{}424242aaáâãäåæµ¥/;

parses 'Single header with whitespace in value', q:to/RESPONSE/,
    HTTP/1.1 200 OK
    Date: Mon, 27 Jul 2009 12:28:53 GMT

    RESPONSE
    *.http-version eq '1.1',
    *.status == 200,
    *.headers == 1,
    *.headers[0].name eq 'Date',
    *.headers[0].value eq 'Mon, 27 Jul 2009 12:28:53 GMT';

parses 'Response with multiple headers and content-length body (example from RFC)',
    q:to/RESPONSE/,
    HTTP/1.1 200 OK
    Date: Mon, 27 Jul 2009 12:28:53 GMT
    Server: Apache
    Last-Modified: Wed, 22 Jul 2009 19:15:56 GMT
    ETag: "34aa387-d-1568eb00"
    Accept-Ranges: bytes
    Content-Length: 51
    Vary: Accept-Encoding
    Content-Type: text/plain

    abcdefghijabcdefghijabcdefghijabcdefghijabcdefghij
    RESPONSE
    *.http-version eq '1.1',
    *.status == 200,
    *.headers == 8,
    *.headers[0].name eq 'Date',
    *.headers[0].value eq 'Mon, 27 Jul 2009 12:28:53 GMT',
    *.headers[1].name eq 'Server',
    *.headers[1].value eq 'Apache',
    *.headers[2].name eq 'Last-Modified',
    *.headers[2].value eq 'Wed, 22 Jul 2009 19:15:56 GMT',
    *.headers[3].name eq 'ETag',
    *.headers[3].value eq '"34aa387-d-1568eb00"',
    *.headers[4].name eq 'Accept-Ranges',
    *.headers[4].value eq 'bytes',
    *.headers[5].name eq 'Content-Length',
    *.headers[5].value eq '51',
    *.headers[6].name eq 'Vary',
    *.headers[6].value eq 'Accept-Encoding',
    *.headers[7].name eq 'Content-Type',
    *.headers[7].value eq 'text/plain',
    *.body-text.result eq "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghij\n";

parses 'Response with body terminated by close of connection',
    q:to/RESPONSE/,
    HTTP/1.1 200 OK

    This is a poem,
    And it's length? Heck knows!
    It will ramble on,
    'til connection close.
    RESPONSE
    *.http-version eq '1.1',
    *.status == 200,
    *.headers == 0,
    *.body-text.result eq "This is a poem,\nAnd it's length? Heck knows!\n" ~
                          "It will ramble on,\n'til connection close.\n";

parses 'Connection close with incomplete body throws',
    q:to/RESPONSE/,
    HTTP/1.1 200 OK
    Content-length: 1000

    Far too short
    RESPONSE
    *.http-version eq '1.1',
    *.status == 200,
    *.headers == 1,
    {
        try await .body-text;
        $!.isa(X::Crow::HTTP::RawBodyParser::ContentLength::TooShort)
    }

parses 'Response with chunked encoding', q:b:to/RESPONSE/.chop,
    HTTP/1.1 200 OK
    Content-type: text/plain
    Transfer-encoding: chunked

    13\r\nThe first response
    \r\n20\r\nThe second
    with a newline in it
    \r\n0\r\n\r\n
    RESPONSE
    *.http-version eq '1.1',
    *.status == 200,
    *.headers == 2,
    *.body-text.result eq "The first response\nThe second\nwith a newline in it\n";

parses 'A text/whatever response has Str .body', q:b:to/RESPONSE/,
    HTTP/1.1 200 OK
    Content-type: text/plain
    Content-Length: 51

    abcdefghijabcdefghijabcdefghijabcdefghijabcdefghij
    RESPONSE
    {
        my $body = .body.result;
        $body ~~ Str && $body eq "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghij\n"
    };

parses 'A unknown/foo response has Blob .body', q:b:to/RESPONSE/,
    HTTP/1.1 200 OK
    Content-type: unknown/foo
    Content-Length: 11

    abcdefghij
    RESPONSE
    {
        my $body = .body.result;
        $body ~~ Blob && $body.decode('ascii') eq "abcdefghij\n"
    };

parses 'charset in content-type is respected by body-text', q:to/RESPONSE/.chop,
    HTTP/1.1 200 OK
    Content-type: text/plain; charset=windows-1252
    Content-length: 9

    文字化
    RESPONSE
    *.http-version eq '1.1',
    *.status == 200,
    *.headers == 2,
    *.body-text.result eq "æ–‡å­—åŒ–";

parses 'A UTF-8 BOM is respected and stripped', q:to/RESPONSE/,
    HTTP/1.1 200 OK
    Content-type: text/plain
    Content-length: 6

    RESPONSE
    body-blob => Blob.new(0xEF, 0xBB, 0xBF, 0xE6, 0x96, 0x87),
    *.http-version eq '1.1',
    *.status == 200,
    *.headers == 2,
    *.body-text.result eq "文";

parses 'A UTF-16 LE BOM is respected and stripped', q:to/RESPONSE/,
    HTTP/1.1 200 OK
    Content-type: text/plain
    Content-length: 4

    RESPONSE
    body-blob => Blob.new(0xFF, 0xFE, 0x87, 0x65),
    *.http-version eq '1.1',
    *.status == 200,
    *.headers == 2,
    *.body-text.result eq "文";

parses 'A UTF-16 BE BOM is respected and stripped', q:to/RESPONSE/,
    HTTP/1.1 200 OK
    Content-type: text/plain
    Content-length: 4

    RESPONSE
    body-blob => Blob.new(0xFE, 0xFF, 0x65, 0x87),
    *.http-version eq '1.1',
    *.status == 200,
    *.headers == 2,
    *.body-text.result eq "文";

done-testing;
