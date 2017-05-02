use Test;
use Crow::HTTP::Request;
use Crow::HTTP::RequestSerializer;
use Crow::TCP;

sub is-request(Supply $source, Str $expected-output, $desc) {
    my $rs = Crow::HTTP::RequestSerializer.new();
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
        emit Crow::HTTP::Request.new(:method<GET>, :target</>);
    },
    q:to/REQUEST/, 'Basic request with no Host header uses HTTP/1.0';
        GET / HTTP/1.0

        REQUEST

is-request
    supply {
        my $req = Crow::HTTP::Request.new(:method<GET>, :target</>);
        $req.append-header('Host', 'www.perl6.org');
        emit $req;
    },
    q:to/REQUEST/, 'Basic request with Host header uses HTTP/1.1';
        GET / HTTP/1.1
        Host: www.perl6.org

        REQUEST

done-testing;
