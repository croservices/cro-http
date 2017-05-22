use Test;
use Cro::HTTP::Request;
use Cro::HTTP::RequestSerializer;
use Cro::TCP;

sub is-request(Supply $source, Str $expected-output, $desc) {
    my $rs = Cro::HTTP::RequestSerializer.new();
    my $joined-output = Blob.new;
    $rs.transformer($source).tap: -> $tcp-message {
        $joined-output ~= $tcp-message.data;
    }
    my ($header, $body) = $expected-output.split("\n\n", 2);
    $header .= subst("\n", "\r\n", :g);
    my $expected-buf = "$header\r\n\r\n".encode('latin-1') ~ $body.encode('utf-8');
    is $joined-output.decode('utf-8'), $expected-buf.decode('utf-8'), $desc;
}

is-request
    supply {
        emit Cro::HTTP::Request.new(:method<GET>, :target</>);
    },
    q:to/REQUEST/, 'Basic request with no Host header uses HTTP/1.0';
        GET / HTTP/1.0

        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</>);
        $req.append-header('Host', 'www.perl6.org');
        emit $req;
    },
    q:to/REQUEST/, 'Basic request with Host header uses HTTP/1.1';
        GET / HTTP/1.1
        Host: www.perl6.org

        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<POST>, :target</foo>);
        $req.append-header('Host', 'localhost');
        $req.set-body(Blob.new(65, 67, 69));
        emit $req;
    },
    q:to/REQUEST/.chop, 'Basic request with blob body adds application/octet-stream and length';
        POST /foo HTTP/1.1
        Host: localhost
        Content-type: application/octet-stream
        Content-length: 3

        ACE
        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<POST>, :target</foo>);
        $req.append-header('Host', 'localhost');
        $req.append-header('Content-type', 'image/gif');
        $req.set-body(Blob.new(71, 73, 70));
        emit $req;
    },
    q:to/REQUEST/.chop, 'Basic request with blob body does not replace existing content-type';
        POST /foo HTTP/1.1
        Host: localhost
        Content-type: image/gif
        Content-length: 3

        GIF
        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<POST>, :target</foo>);
        $req.append-header('Host', 'localhost');
        $req.set-body("Wow it's text");
        emit $req;
    },
    q:to/REQUEST/.chop, 'Basic request with string body adds text/plain and length';
        POST /foo HTTP/1.1
        Host: localhost
        Content-type: text/plain; charset="utf-8"
        Content-length: 13

        Wow it's text
        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<POST>, :target</foo>);
        $req.append-header('Host', 'localhost');
        $req.append-header('Content-type', 'text/css');
        $req.set-body('.danger { color: red }');
        emit $req;
    },
    q:to/REQUEST/.chop, 'Basic request with string body does not replace existing content-type';
        POST /foo HTTP/1.1
        Host: localhost
        Content-type: text/css
        Content-length: 22

        .danger { color: red }
        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<POST>, :target</foo>);
        $req.append-header('Host', 'localhost');
        $req.append-header('Content-type', 'application/json');
        $req.set-body({ foo => [1,2,3] });
        emit $req;
    },
    q:to/REQUEST/.chop, 'application/json content serializes Hash to JSON';
        POST /foo HTTP/1.1
        Host: localhost
        Content-type: application/json
        Content-length: 16

        {"foo": [1,2,3]}
        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<POST>, :target</foo>);
        $req.append-header('Host', 'localhost');
        $req.append-header('Content-type', 'application/json');
        $req.set-body([4,5,6]);
        emit $req;
    },
    q:to/REQUEST/.chop, 'application/json content serializes Array to JSON';
        POST /foo HTTP/1.1
        Host: localhost
        Content-type: application/json
        Content-length: 7

        [4,5,6]
        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<POST>, :target</foo>);
        $req.append-header('Host', 'localhost');
        $req.append-header('Content-type', 'application/vnd.foobar+json');
        $req.set-body({ foo => [1,2,3] });
        emit $req;
    },
    q:to/REQUEST/.chop, 'Media type with +json suffix also serializes JSON';
        POST /foo HTTP/1.1
        Host: localhost
        Content-type: application/vnd.foobar+json
        Content-length: 16

        {"foo": [1,2,3]}
        REQUEST

done-testing;
