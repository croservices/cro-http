use Cro::HTTP2::Frame;
use Cro::HTTP2::ResponseSerializer;
use Cro::HTTP::Request;
use Cro::HTTP::Response;
use HTTP::HPACK;
use Test;

my ($req, @headers, $body);
my $decoder = HTTP::HPACK::Decoder.new;
my $encoder = HTTP::HPACK::Encoder.new;

sub test(@requests, $count, $desc, *@checks) {
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
        for @requests {
            $fake-in.emit($_)
        }
        $fake-in.done;
    }
    await Promise.anyof($test-completed, Promise.in(5));
    if $test-completed.status ~~ Kept {
        pass $desc;
    } else {
        flunk $desc;
    }
}

@headers = HTTP::HPACK::Header.new(name => 'ETag', value => 'xyzzy'),
           HTTP::HPACK::Header.new(name => ':status', value => '304');

$req = Cro::HTTP::Response.new(:304status,
                               request => Cro::HTTP::Request.new(:5http2-stream-id));
$req.append-header('ETag' => 'xyzzy');
test [$req], 1, 'Header',
     [[(* ~~ Cro::HTTP2::Frame::Headers),
       (*.flags == 5),
       (*.stream-identifier == 5),
       (*.headers eq $encoder.encode-headers(@headers))],];

@headers = HTTP::HPACK::Header.new(name => 'Content-Type', value => 'image/jpeg'),
           HTTP::HPACK::Header.new(name => 'Content-length', value => '123'),
           HTTP::HPACK::Header.new(name => ':status', value => '200');
$body = Buf.new: <0 1>.pick xx 123;

$req = Cro::HTTP::Response.new(:200status,
                               request => Cro::HTTP::Request.new(:5http2-stream-id));
$req.append-header('Content-Type' => 'image/jpeg');
$req.append-header('Content-length' => '123');
$req.set-body: $body;
test [$req], 2, 'Header + Data',
     [[(* ~~ Cro::HTTP2::Frame::Headers),
       (*.flags == 4),
       (*.stream-identifier == 5),
       (*.headers eq $encoder.encode-headers(@headers))],
      [(* ~~ Cro::HTTP2::Frame::Data),
       (*.flags == 1),
       (*.stream-identifier == 5),
       (*.data eq $body)]];

done-testing;
