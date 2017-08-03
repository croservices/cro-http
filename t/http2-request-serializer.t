use Cro::HTTP2::Frame;
use Cro::HTTP2::RequestSerializer;
use Cro::HTTP::Request;
use Cro::HTTP::Response;
use HTTP::HPACK;
use Test;

my ($req, @headers, $body);
my $encoder;

sub test($request, $count, $desc, *@checks, :$fail) {
    my $test-completed = Promise.new;
    my $serializer = Cro::HTTP2::RequestSerializer;
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
        $fake-in.emit($request);
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

$req = Cro::HTTP::Request.new(:method<GET>,
                              :target</resource>,
                              :5http2-stream-id);
@headers = HTTP::HPACK::Header.new(name => ':method', value => 'GET'),
           HTTP::HPACK::Header.new(name => ':scheme', value => 'https'),
           HTTP::HPACK::Header.new(name => ':path',   value => '/resource'),
           HTTP::HPACK::Header.new(name => 'host',    value => 'example.org'),
           HTTP::HPACK::Header.new(name => 'accept',  value => 'image/jpeg');
$req.append-header('host' => 'example.org');
$req.append-header('accept' => 'image/jpeg');
$encoder = HTTP::HPACK::Encoder.new;
test $req, 1, 'Header',
    [[(* ~~ Cro::HTTP2::Frame::Headers),
      (*.flags == 5),
      (*.stream-identifier == 5),
      (*.headers eq $encoder.encode-headers(@headers))],];

$req = Cro::HTTP::Request.new(:method<POST>,
                              :target</resource>,
                              :5http2-stream-id);
$encoder = HTTP::HPACK::Encoder.new;
@headers = HTTP::HPACK::Header.new(name => ':method',        value => 'POST'),
           HTTP::HPACK::Header.new(name => ':scheme',        value => 'https'),
           HTTP::HPACK::Header.new(name => ':path',          value => '/resource'),
           HTTP::HPACK::Header.new(name => 'host',           value => 'example.org'),
           HTTP::HPACK::Header.new(name => 'content-type',   value => 'image/jpeg'),
           HTTP::HPACK::Header.new(name => 'content-length', value => '123');

$body = Supplier::Preserving.new;
my $random = Buf.new: <0 1>.pick xx 123;
$body.emit: $random;
$body.done;
$req.append-header('host' => 'example.org');
$req.append-header('content-type' => 'image/jpeg');
$req.append-header('content-length' => '123');
$req.set-body-byte-stream: $body.Supply;

$encoder = HTTP::HPACK::Encoder.new;
test $req, 2, 'Header + Data',
    [[(* ~~ Cro::HTTP2::Frame::Headers),
      (*.flags == 4),
      (*.stream-identifier == 5),
      (*.headers eq $encoder.encode-headers(@headers))],
     [(* ~~ Cro::HTTP2::Frame::Data),
      (*.flags == 1),
      (*.stream-identifier == 5),
      (*.data eq $random)]];

$req = Cro::HTTP::Request.new(:method<POST>,
                              :target</resource>,
                              :5http2-stream-id);
$encoder = HTTP::HPACK::Encoder.new;
@headers = HTTP::HPACK::Header.new(name => ':method',        value => 'POST'),
           HTTP::HPACK::Header.new(name => ':scheme',        value => 'https'),
           HTTP::HPACK::Header.new(name => ':path',          value => '/resource'),
           HTTP::HPACK::Header.new(name => 'host',           value => 'example.org'),
           HTTP::HPACK::Header.new(name => 'content-type',   value => 'image/jpeg');

$body = Supplier::Preserving.new;
$random = Buf.new: <0 1>.pick xx 123;
$body.emit: $random;
$body.done;
$req.append-header('host' => 'example.org');
$req.append-header('content-type' => 'image/jpeg');
$req.set-body-byte-stream: $body.Supply;

$encoder = HTTP::HPACK::Encoder.new;
test $req, 3, 'Header + Data with unknown Content-Length',
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

done-testing;
