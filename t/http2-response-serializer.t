use Cro::HTTP2::Frame;
use Cro::HTTP2::ResponseSerializer;
use Cro::HTTP::Request;
use Cro::HTTP::Response;
use HTTP::HPACK;
use Test;

my ($resp, @headers, $body);
my $encoder = HTTP::HPACK::Encoder.new;

sub test($response, $count, $desc, *@checks, :$fail) {
    my $test-completed = Promise.new;
    my $serializer = Cro::HTTP2::ResponseSerializer.new;
    my $fake-in = Supplier.new;
    my $counter = 0;
    $serializer.transformer($fake-in.Supply).tap:
    -> $frame {
        for @checks[$counter].kv -> $i, $check {
            ok $check($frame), "check {$i + 1}";
        }
        $counter++;
        $test-completed.keep if $counter == $count;
    },
    quit => {
        $test-completed.break;
    }
    start {
        $fake-in.emit($response);
        $fake-in.done;
    }
    await Promise.anyof($test-completed, Promise.in(5));
    if $test-completed.status ~~ Kept {
        pass $desc;
    } else {
        die if $fail;
        flunk $desc unless $fail;
    }
}

@headers = HTTP::HPACK::Header.new(name => ':status', value => '304'),
           HTTP::HPACK::Header.new(name => 'etag', value => 'xyzzy');

$resp = Cro::HTTP::Response.new(:304status,
                               request => Cro::HTTP::Request.new(:5http2-stream-id));
$resp.append-header('etag' => 'xyzzy');
$encoder = HTTP::HPACK::Encoder.new;
test $resp, 1, 'Header',
     [[(* ~~ Cro::HTTP2::Frame::Headers),
       (*.flags == 5),
       (*.stream-identifier == 5),
       (*.headers eq $encoder.encode-headers(@headers))],];

@headers = HTTP::HPACK::Header.new(name => ':status', value => '200'),
           HTTP::HPACK::Header.new(name => 'content-type', value => 'image/jpeg'),
           HTTP::HPACK::Header.new(name => 'content-length', value => '123');
$body = Buf.new: <0 1>.pick xx 123;

$resp = Cro::HTTP::Response.new(:200status,
                               request => Cro::HTTP::Request.new(:5http2-stream-id));
$resp.append-header('content-type' => 'image/jpeg');
$resp.append-header('content-length' => '123');
$resp.set-body: $body;
test $resp, 2, 'Header + Data',
     [[(* ~~ Cro::HTTP2::Frame::Headers),
       (*.flags == 4),
       (*.stream-identifier == 5),
       (*.headers eq $encoder.encode-headers(@headers))],
      [(* ~~ Cro::HTTP2::Frame::Data),
       (*.flags == 1),
       (*.stream-identifier == 5),
       (*.data eq $body)]];

$encoder = HTTP::HPACK::Encoder.new;
@headers = HTTP::HPACK::Header.new(name => ':status', value => '200'),
           HTTP::HPACK::Header.new(name => 'content-type', value => 'image/jpeg');

$body = Supplier::Preserving.new;
my $random = Buf.new: <0 1>.pick xx 150;
$body.emit: $random;
$body.done;
$resp = Cro::HTTP::Response.new(:200status,
                               request => Cro::HTTP::Request.new(:5http2-stream-id));
$resp.append-header('content-type' => 'image/jpeg');
$resp.set-body: $body.Supply;
test $resp, 3, 'Header + Data - Content-Length unspecified',
     [[(* ~~ Cro::HTTP2::Frame::Headers),
       (*.flags == 4),
       (*.stream-identifier == 5),
       (*.headers eq $encoder.encode-headers(@headers))],
      [(* ~~ Cro::HTTP2::Frame::Data),
       (*.flags == 0),
       (*.stream-identifier == 5),
       (*.data eq $random)],
      [(* ~~ Cro::HTTP2::Frame::Data),
       (*.flags == 1),
       (*.stream-identifier == 5),
       (*.data eq Buf.new)]];

dies-ok {
    my $body = Supplier::Preserving.new;
    $body.emit: Buf.new: <0 1>.pick xx 100;
    $body.done;
    $resp = Cro::HTTP::Response.new(:200status,
                                   request => Cro::HTTP::Request.new(:5http2-stream-id));
    $resp.append-header('Content-length' => '123');
    $resp.set-body: $body.Supply;
    test $resp, 3, 'Header + Data', [], :fail;
}, 'Too small body throws';

dies-ok {
    my $body = Supplier::Preserving.new;
    $body.emit: Buf.new: <0 1>.pick xx 123;
    $body.done;
    $resp = Cro::HTTP::Response.new(:200status,
                                   request => Cro::HTTP::Request.new(:5http2-stream-id));
    $resp.append-header('Content-length' => '100');
    $resp.set-body: $body.Supply;
    test $resp, 3, 'Header + Data', [], :fail;
}, 'Too big body throws';

done-testing;
