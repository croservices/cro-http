use Crow::HTTP::ResponseParser;
use Crow::HTTP::Response;
use Crow::TCP;
use Test;

ok Crow::HTTP::ResponseParser ~~ Crow::Processor,
    'HTTP response parser is a processor';
ok Crow::HTTP::ResponseParser.consumes === Crow::TCP::Message,
    'HTTP response parser consumes TCP messages';
ok Crow::HTTP::ResponseParser.produces === Crow::HTTP::Response,
    'HTTP respose parser produces HTTP responses';

sub test-response-to-tcp-message($res) {
    # We replace \n with \r\n in the response headers here, so the tests can
    # look pretty.
    my ($headers, $body) = $res.split(/\n\n/);
    $headers .= subst("\n", "\r\n", :g);
    my $data = "$headers\r\n\r\n$body".encode('latin-1');
    return Crow::TCP::Message.new(:$data);
}

sub parses($desc, $test-response, *@checks, *%config) {
    my $testee = Crow::HTTP::ResponseParser.new(|%config);
    my $fake-in = Supplier.new;
    $testee.processor($fake-in.Supply).tap:
        -> $response {
            pass $desc;
            for @checks.kv -> $i, $check {
                ok $check($response), "check {$i + 1 }";
            }
            return;
        },
        quit => {
            diag "Response parsing failed: $_";
            flunk $desc;
            skip 'Failed to parse', @checks.elems;
            return;
        };
    $fake-in.emit(test-response-to-tcp-message($test-response));

    # We only reach here if we fail emit a HTTP message (see `return`s above).
    diag 'Response parser failed to emit a HTTP response';
    flunk $desc;
    skip 'Did not get response', @checks.elems;
}

sub refuses($desc, $test-response, *%config) {
    my $testee = Crow::HTTP::ResponseParser.new(|%config);
    my $fake-in = Supplier.new;
    $testee.processor($fake-in.Supply).tap:
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

# TODO:
# * Tests for what chars are valid in reason (no controls!)
# * Tests for header parsing
