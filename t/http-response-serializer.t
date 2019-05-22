use Test;
use Cro::HTTP::Response;
use Cro::HTTP::ResponseSerializer;
use Cro::TCP;
use Log::Timeline;

sub is-response(Supply $source, Str $expected-output, $desc) {
    my $rs = Cro::HTTP::ResponseSerializer.new();
    my $joined-output = Blob.new;
    $rs.transformer($source).tap: -> $tcp-message {
        $joined-output ~= $tcp-message.data;
    }
    my ($header, $body) = $expected-output.split("\n\n", 2);
    $header .= subst("\n", "\r\n", :g);
    my $expected-buf = "$header\r\n\r\n".encode('latin-1') ~ $body.encode('utf-8');
    is $joined-output.decode('utf-8'), $expected-buf.decode('utf-8'), $desc;
}

# Fake request for testing purposes.
my $request = Cro::HTTP::Request.new(:http-version<1.1>);
$request.annotations<timeline-request> = Log::Timeline::Ongoing::Unlogged;

is-response
    supply {
        emit Cro::HTTP::Response.new(:204status, :$request);
    },
    q:to/RESPONSE/, 'Basic 204 status response serialized correctly';
        HTTP/1.1 204 No Content

        RESPONSE

is-response
    supply {
        given Cro::HTTP::Response.new(:200status, :$request) {
            .append-header('Content-type', 'text/plain');
            .set-body("Wow it's like, plain text!\n".encode('utf-8'));
            .emit;
        }
    },
    q:to/RESPONSE/, '200 response with body readily available emits Content-length';
        HTTP/1.1 200 OK
        Content-type: text/plain
        Content-length: 27

        Wow it's like, plain text!
        RESPONSE

is-response
    supply {
        given Cro::HTTP::Response.new(:200status, :$request) {
            my $body-stream = supply {
                emit "The first response\n".encode('utf-8');
                emit "The second\nwith a newline in it\n".encode('utf-8');
            }
            .append-header('Content-type', 'text/plain');
            .set-body($body-stream);
            .emit;
        }
    },
    q:b:to/RESPONSE/.chop, '200 response with streaming body does chunked encoding';
        HTTP/1.1 200 OK
        Content-type: text/plain
        Transfer-encoding: chunked

        13\r\nThe first response
        \r\n20\r\nThe second
        with a newline in it
        \r\n0\r\n\r\n
        RESPONSE

is-response
    supply {
        given Cro::HTTP::Response.new(:200status, :$request) {
            my $body-stream = supply {
                emit "Not confused ".encode('utf-8');
                emit Blob.new;
                emit "by emptiness\n".encode('utf-8');
            }
            .append-header('Content-type', 'text/plain');
            .set-body($body-stream);
            .emit;
        }
    },
    q:b:to/RESPONSE/.chop, 'Chunked encoding not messed up by empty blobs';
        HTTP/1.1 200 OK
        Content-type: text/plain
        Transfer-encoding: chunked

        D\r\nNot confused \r\nD\r\nby emptiness
        \r\n0\r\n\r\n
        RESPONSE

is-response
    supply {
        given Cro::HTTP::Response.new(:200status, :$request) {
            .append-header('Content-type', 'application/json');
            .set-body({});
            .emit;
        }
    },
    q:b:to/RESPONSE/.chop, 'application/json encodes Hash as JSON';
        HTTP/1.1 200 OK
        Content-type: application/json
        Content-length: 2

        {}
        RESPONSE

is-response
    supply {
        given Cro::HTTP::Response.new(:200status, :$request) {
            .append-header('Content-type', 'application/json');
            .set-body([4,5,6]);
            .emit;
        }
    },
    q:b:to/RESPONSE/.chop, 'application/json encodes Array as JSON';
        HTTP/1.1 200 OK
        Content-type: application/json
        Content-length: 7

        [4,5,6]
        RESPONSE

is-response
    supply {
        given Cro::HTTP::Response.new(:200status, :$request) {
            .append-header('Content-type', 'application/vnd.foobar+json');
            .set-body({});
            .emit;
        }
    },
    q:b:to/RESPONSE/.chop, 'application/vnd.foobar+json encodes Hash as JSON';
        HTTP/1.1 200 OK
        Content-type: application/vnd.foobar+json
        Content-length: 2

        {}
        RESPONSE

done-testing;
