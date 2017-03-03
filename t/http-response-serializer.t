use Test;
use Crow::HTTP::Response;
use Crow::HTTP::ResponseSerializer;
use Crow::TCP;

sub is-response(Supply $source, Str $expected-output, $desc) {
    my $rs = Crow::HTTP::ResponseSerializer.new();
    my $joined-output = Blob.new;
    $rs.transformer($source).tap: -> $tcp-message {
        $joined-output ~= $tcp-message.data;
    }
    my ($header, $body) = $expected-output.split("\n\n", 2);
    $header .= subst("\n", "\r\n", :g);
    my $expected-buf = "$header\r\n\r\n".encode('latin-1') ~ $body.encode('utf-8');
    is-deeply $joined-output, $expected-buf, $desc;
}

is-response
    supply {
        emit Crow::HTTP::Response.new(:204status);
    },
    q:to/RESPONSE/, 'Basic 204 status response serialized correctly';
        HTTP/1.1 204 No Content

        RESPONSE

is-response
    supply {
        given Crow::HTTP::Response.new(:200status) {
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

done-testing;
