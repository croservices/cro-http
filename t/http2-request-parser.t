use HTTP::HPACK;
use Cro::HTTP2::RequestParser;
use Cro::HTTP2::Frame;
use Cro::HTTP::Request;
use Test;

my $encoder = HTTP::HPACK::Encoder.new;
my ($buf, @headers);

sub test(@frames, $desc, *@checks) {
    my $parser = Cro::HTTP2::RequestParser;
    my $fake-in = Supplier.new;
    my $test-completed = Promise.new;
    $parser.transformer($fake-in.Supply).schedule-on($*SCHEDULER).tap:
    -> $request {
        pass $desc;
        for @checks.kv -> $i, $check {
            ok $check($request), "check {$i + 1}";
        }
        $test-completed.keep;
    },
    quit => {
        note $_;
        flunk $desc;
        $test-completed.keep;
    }
    start {
        for @frames {
            $fake-in.emit($_)
        }
        $fake-in.done;
    }
    await Promise.anyof($test-completed, Promise.in(5));
    unless $test-completed {
        flunk $desc;
    }
}

@headers = HTTP::HPACK::Header.new(name => ':method', value => 'GET'),
           HTTP::HPACK::Header.new(name => ':path',   value => '/resource'),
           HTTP::HPACK::Header.new(name => ':scheme', value => 'https'),
           HTTP::HPACK::Header.new(name => 'host',    value => 'example.org'),
           HTTP::HPACK::Header.new(name => 'accept',  value => 'image/jpeg');

test (Cro::HTTP2::Frame::Headers.new(
             stream-identifier => 1,
             flags => 5,
             headers => $encoder.encode-headers(@headers))).List,
     'Simple header frame',
     (*.method eq 'GET'),
     (*.target eq '/resource'),
     (*.header('Host') eq 'example.org'),
     (*.header('Accept') eq 'image/jpeg');

$encoder = HTTP::HPACK::Encoder.new;
@headers = HTTP::HPACK::Header.new(name => ':method', value => 'POST'),
           HTTP::HPACK::Header.new(name => ':path',   value => '/resource'),
           HTTP::HPACK::Header.new(name => ':scheme', value => 'https'),
           HTTP::HPACK::Header.new(name => 'host',    value => 'example.org'),
           HTTP::HPACK::Header.new(name => 'content-type',   value => 'image/jpeg'),
           HTTP::HPACK::Header.new(name => 'content-length', value => '123');

my $payload = Buf.new(<0 1>.pick xx 20);
test (Cro::HTTP2::Frame::Headers.new(
             stream-identifier => 1,
             flags => 0,
             headers => $encoder.encode-headers(@headers[0..2])),
      Cro::HTTP2::Frame::Continuation.new(
             stream-identifier => 1,
             flags => 4,
             headers => $encoder.encode-headers(@headers[3..5])),
      Cro::HTTP2::Frame::Data.new(
             stream-identifier => 1,
             flags => 1,
             data => $payload)),
     'Headers + Continuation + Data',
     (*.method eq 'POST'),
     (*.target eq '/resource'),
     (*.header('Host') eq 'example.org'),
     (*.header('Content-type')   eq 'image/jpeg'),
     (*.header('Content-length') eq '123'),
     (*.body-blob.result eq $payload);

done-testing;
