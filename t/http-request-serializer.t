use Test;
use Cro::HTTP::Body;
use Cro::HTTP::Request;
use Cro::HTTP::RequestSerializer;
use Cro::TCP;

sub is-request(Supply $source, Str $expected-output, $desc, :$rx) {
    my $rs = Cro::HTTP::RequestSerializer.new();
    my $joined-output = Blob.new;
    $rs.transformer($source).tap: -> $tcp-message {
        $joined-output ~= $tcp-message.data;
    }
    if $rx {
        like $joined-output.decode('utf-8'), /<$expected-output>/, $desc;
    }
    else {
        my ($header, $body) = $expected-output.split("\n\n", 2);
        $header .= subst("\n", "\r\n", :g);
        my $expected-buf = "$header\r\n\r\n".encode('latin-1') ~ $body.encode('utf-8');
        is $joined-output.decode('utf-8'), $expected-buf.decode('utf-8'), $desc;
    }
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
        $req.set-body({});
        emit $req;
    },
    q:to/REQUEST/.chop, 'application/json content serializes Hash to JSON';
        POST /foo HTTP/1.1
        Host: localhost
        Content-type: application/json
        Content-length: 2

        {}
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
        $req.set-body([1,2,3]);
        emit $req;
    },
    q:to/REQUEST/.chop, 'Media type with +json suffix also serializes JSON';
        POST /foo HTTP/1.1
        Host: localhost
        Content-type: application/vnd.foobar+json
        Content-length: 7

        [1,2,3]
        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<POST>, :target</foo>);
        $req.append-header('Host', 'localhost');
        $req.append-header('Content-type', 'application/x-www-form-urlencoded');
        $req.set-body([rooms => 2, balcony => 'true', area => 'Praha 3']);
        emit $req;
    },
    q:to/REQUEST/.chop, 'application/x-www-form-urlencoded with list of pairs';
        POST /foo HTTP/1.1
        Host: localhost
        Content-type: application/x-www-form-urlencoded
        Content-length: 33

        rooms=2&balcony=true&area=Praha+3
        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<POST>, :target</foo>);
        $req.append-header('Host', 'localhost');
        $req.append-header('Content-type', 'application/x-www-form-urlencoded');
        $req.set-body((x => 'A+C', y => '100%AA!', 'A+C' => '1', '100%AA!' => '2'));
        emit $req;
    },
    q:to/REQUEST/.chop, 'application/x-www-form-urlencoded with ASCII things needing escaping';
        POST /foo HTTP/1.1
        Host: localhost
        Content-type: application/x-www-form-urlencoded
        Content-length: 43

        x=A%2BC&y=100%25AA%21&A%2BC=1&100%25AA%21=2
        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<POST>, :target</foo>);
        $req.append-header('Host', 'localhost');
        $req.append-header('Content-type', 'application/x-www-form-urlencoded');
        $req.set-body((
            x => "\c[LATIN CAPITAL LETTER A WITH GRAVE]b",
            "\c[KATAKANA LETTER A]\c[KATAKANA LETTER A]" => '1'
        ));
        emit $req;
    },
    q:to/REQUEST/.chop, 'application/x-www-form-urlencoded with ASCII things needing escaping';
        POST /foo HTTP/1.1
        Host: localhost
        Content-type: application/x-www-form-urlencoded
        Content-length: 30

        x=%C3%80b&%E3%82%A2%E3%82%A2=1
        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<POST>, :target</foo>);
        $req.append-header('Host', 'localhost');
        $req.append-header('Content-type', 'application/x-www-form-urlencoded');
        $req.set-body({ x => 42 }); # Just one elem, to avoid ordering fun...
        emit $req;
    },
    q:to/REQUEST/.chop, 'application/x-www-form-urlencoded with hash';
        POST /foo HTTP/1.1
        Host: localhost
        Content-type: application/x-www-form-urlencoded
        Content-length: 4

        x=42
        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<POST>, :target</foo>);
        $req.append-header('Host', 'localhost');
        $req.append-header('Content-type', 'application/x-www-form-urlencoded');
        $req.set-body(Cro::HTTP::Body::WWWFormUrlEncoded.new(pairs => (
            x => 'A+C', x => '100%AA!', 'A+C' => '1', '100%AA!' => '2'
        )));
        emit $req;
    },
    q:to/REQUEST/.chop, 'application/x-www-form-urlencoded with body object';
        POST /foo HTTP/1.1
        Host: localhost
        Content-type: application/x-www-form-urlencoded
        Content-length: 43

        x=A%2BC&x=100%25AA%21&A%2BC=1&100%25AA%21=2
        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<POST>, :target</foo>);
        $req.append-header('Host', 'localhost');
        $req.set-body(Cro::HTTP::Body::WWWFormUrlEncoded.new(pairs => (
            x => 'A+C', x => '100%AA!', 'A+C' => '1', '100%AA!' => '2'
        )));
        emit $req;
    },
    q:to/REQUEST/.chop, 'application/x-www-form-urlencoded body object implies header';
        POST /foo HTTP/1.1
        Host: localhost
        Content-type: application/x-www-form-urlencoded
        Content-length: 43

        x=A%2BC&x=100%25AA%21&A%2BC=1&100%25AA%21=2
        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<POST>, :target</foo>);
        $req.append-header('Host', 'localhost');
        $req.append-header('Content-type', 'multipart/form-data');
        $req.set-body([a => 3555555555555555551, b => 53399393939222]);
        emit $req;
    },
    Q:to/REQUEST/.chop, :rx, 'multipart/form-data with list of pairs';
        'POST /foo HTTP/1.1' \n
        'Host: localhost' \n
        'Content-type: multipart/form-data; boundary="' $<b>=[<-["]>+] '"' \n
        'Content-length: '\d+ \n
        \n
        '--' $<b> \n
        'Content-Disposition: form-data; name="a"' \n
        \n
        '3555555555555555551' \n
        '--' $<b> \n
        'Content-Disposition: form-data; name="b"' \n
        \n
        '53399393939222' \n
        '--' $<b> '--'  \n
        REQUEST

is-request
    supply {
        my $req = Cro::HTTP::Request.new(:method<POST>, :target</foo>);
        $req.append-header('Host', 'localhost');
        $req.append-header('Content-type', 'multipart/form-data');
        $req.set-body([
            title => 'Wow an image',
            Cro::HTTP::Body::MultiPartFormData::Part.new(
                name => 'image',
                filename => 'foo.gif',
                headers => [Cro::HTTP::Header.new(name => 'Content-type', value => 'image/gif')],
                body-blob => 'GIF'.encode('ascii')
            )
        ]);
        emit $req;
    },
    Q:to/REQUEST/.chop, :rx, 'multipart/form-data with filename and extra header';
        'POST /foo HTTP/1.1' \n
        'Host: localhost' \n
        'Content-type: multipart/form-data; boundary="' $<b>=[<-["]>+] '"' \n
        'Content-length: '\d+ \n
        \n
        '--' $<b> \n
        'Content-Disposition: form-data; name="title"' \n
        \n
        'Wow an image' \n
        '--' $<b> \n
        'Content-Disposition: form-data; name="image"; filename="foo.gif"' \n
        'Content-type: image/gif' \n
        \n
        'GIF' \n
        '--' $<b> '--'  \n
        REQUEST

done-testing;
