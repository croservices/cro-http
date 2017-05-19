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

done-testing;
