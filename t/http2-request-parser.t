use HTTP::HPACK;
use Cro::HTTP2::RequestParser;
use Cro::HTTP2::Frame;
use Cro::HTTP::Request;
use Test;

my $encoder = HTTP::HPACK::Encoder.new;
my ($buf, @headers);

sub test(@frames, $count, $desc, @checks, :$fail, :$test-supplies) {
    my $test-completed = Promise.new;
    my $connection-state = Cro::HTTP2::ConnectionState.new;
    with $test-supplies {
        my $ping = $connection-state.ping.Supply;
        $ping.tap(
            -> $_ {
                $test-completed.keep;
                $test-supplies.keep;
            });
    }
    my $parser = Cro::HTTP2::RequestParser.new;
    my $fake-in = Supplier.new;
    my $counter = 0;
    $parser.transformer($fake-in.Supply, :$connection-state).tap:
    -> $request {
        for @checks[$counter].kv -> $i, $check {
            ok $check($request), "check {$i + 1}";
        }
        $counter++;
        $test-completed.keep if $counter == $count;
    },
    quit => {
        $test-completed.break;
    }
    start {
        for @frames {
            $fake-in.emit($_)
        }
        $fake-in.done;
    }
    await Promise.anyof($test-completed, Promise.in(5));
    if $test-completed.status ~~ Kept {
        pass $desc;
    } else {
        die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR) if $fail;
        flunk $desc unless $test-supplies;
    }
}

@headers = HTTP::HPACK::Header.new(name => ':method', value => 'GET'),
           HTTP::HPACK::Header.new(name => ':path',   value => '/resource'),
           HTTP::HPACK::Header.new(name => ':scheme', value => 'https'),
           HTTP::HPACK::Header.new(name => 'host',    value => 'example.org'),
           HTTP::HPACK::Header.new(name => 'accept',  value => 'image/jpeg');

test (Cro::HTTP2::Frame::Headers.new(
             stream-identifier => 3,
             flags => 5,
             headers => $encoder.encode-headers(@headers))).List,
     1, 'Headers',
     [[(*.method eq 'GET'),
       (*.target eq '/resource'),
       (*.http-version eq '2.0'),
       (*.header('Host') eq 'example.org'),
       (*.header('Accept') eq 'image/jpeg')],];

$encoder = HTTP::HPACK::Encoder.new;
@headers = HTTP::HPACK::Header.new(name => ':method', value => 'POST'),
           HTTP::HPACK::Header.new(name => ':path',   value => '/resource'),
           HTTP::HPACK::Header.new(name => ':scheme', value => 'https'),
           HTTP::HPACK::Header.new(name => 'host',    value => 'example.org'),
           HTTP::HPACK::Header.new(name => 'content-type',   value => 'image/jpeg'),
           HTTP::HPACK::Header.new(name => 'content-length', value => '123'),
           HTTP::HPACK::Header.new(name => 'foo', value => 'bar');

$buf = $encoder.encode-headers(@headers);
test (Cro::HTTP2::Frame::Headers.new(
             stream-identifier => 3,
             flags => 1,
             headers => $buf.subbuf(0, 10)),
      Cro::HTTP2::Frame::Continuation.new(
             stream-identifier => 3,
             flags => 4,
             headers => $buf.subbuf(10))),
     1, 'Headers + Continuation',
     [[(*.method eq 'POST'),
       (*.target eq '/resource'),
       (*.http-version eq '2.0'),
       (*.header('Host') eq 'example.org'),
       (*.header('Content-type')   eq 'image/jpeg'),
       (*.header('Content-length') eq '123')],];

$encoder = HTTP::HPACK::Encoder.new;
my $payload = Buf.new(<0 1>.pick xx 20);
test (Cro::HTTP2::Frame::Headers.new(
             stream-identifier => 3,
             flags => 4,
             headers => $encoder.encode-headers(@headers[0..2])),
      Cro::HTTP2::Frame::Data.new(
             stream-identifier => 3,
             flags => 1,
             data => $payload)),
     1, 'Headers + Data',
     [[(*.method eq 'POST'),
       (*.target eq '/resource'),
       (*.http-version eq '2.0'),
       (*.body-blob.result eq $payload)],];

$encoder = HTTP::HPACK::Encoder.new;
$buf = $encoder.encode-headers(@headers);
$payload = Buf.new(<0 1>.pick xx 20);
test (Cro::HTTP2::Frame::Headers.new(
             stream-identifier => 3,
             flags => 0,
             headers => $buf.subbuf(0,10)),
      Cro::HTTP2::Frame::Continuation.new(
             stream-identifier => 3,
             flags => 4,
             headers => $buf.subbuf(10)),
      Cro::HTTP2::Frame::Data.new(
             stream-identifier => 3,
             flags => 1,
             data => $payload)),
      1, 'Headers + Continuation + Data',
      [[(*.method eq 'POST'),
        (*.target eq '/resource'),
        (*.http-version eq '2.0'),
        (*.header('Host') eq 'example.org'),
        (*.header('Content-type')   eq 'image/jpeg'),
        (*.header('Content-length') eq '123'),
        (*.body-blob.result eq $payload)],];

$encoder = HTTP::HPACK::Encoder.new;
$buf = $encoder.encode-headers(@headers[0..5]);
$payload = Buf.new(<0 1>.pick xx 123);
test (Cro::HTTP2::Frame::Headers.new(
             stream-identifier => 3,
             flags => 0,
             headers => $buf.subbuf(0,10)),
      Cro::HTTP2::Frame::Continuation.new(
             stream-identifier => 3,
             flags => 4,
             headers => $buf.subbuf(10)),
      Cro::HTTP2::Frame::Data.new(
             stream-identifier => 3,
             flags => 0,
             data => $payload),
      Cro::HTTP2::Frame::Headers.new(
             stream-identifier => 3,
             flags => 5,
             headers => $encoder.encode-headers(@headers[6].List))),
     1, 'Headers + Continuation + Data + Headers',
     [[(*.method eq 'POST'),
       (*.target eq '/resource'),
       (*.http-version eq '2.0'),
       (*.header('Host') eq 'example.org'),
       (*.header('content-type')   eq 'image/jpeg'),
       (*.header('content-length') eq '123'),
       (*.body-blob.result eq $payload),
       (*.header('foo') eq 'bar')],];

# Multiplexing

$encoder = HTTP::HPACK::Encoder.new;
test (Cro::HTTP2::Frame::Headers.new(
          stream-identifier => 3,
          flags => 4,
          headers => $encoder.encode-headers(@headers[0..3])),
      Cro::HTTP2::Frame::Headers.new(
          stream-identifier => 5,
          flags => 5,
          headers => $encoder.encode-headers(@headers[0..3])),
      Cro::HTTP2::Frame::Data.new(
          stream-identifier => 3,
          flags => 1,
          data => $payload)),
     2, 'Header1 + Header2 + Data1',
     [[(*.method eq 'POST'),
       (*.http-version eq '2.0'),
       (*.target eq '/resource')],
      [(*.method eq 'POST'),
       (*.http-version eq '2.0'),
       (*.target eq '/resource'),
       (*.body-blob.result eq $payload)]];

$encoder = HTTP::HPACK::Encoder.new;
test (Cro::HTTP2::Frame::Headers.new(
          stream-identifier => 3,
          flags => 4,
          headers => $encoder.encode-headers(@headers[0..3])),
      Cro::HTTP2::Frame::Headers.new(
          stream-identifier => 5,
          flags => 4,
          headers => $encoder.encode-headers(@headers[0..3])),
      Cro::HTTP2::Frame::Data.new(
          stream-identifier => 3,
          flags => 1,
          data => $payload),
      Cro::HTTP2::Frame::Data.new(
          stream-identifier => 5,
          flags => 1,
          data => $payload ~ $payload)),
     2, 'Header1 + Header2 + Data1 + Data2',
     [[(*.method eq 'POST'),
       (*.target eq '/resource'),
       (*.http-version eq '2.0'),
       (*.body-blob.result eq $payload)],
      [(*.method eq 'POST'),
       (*.target eq '/resource'),
       (*.http-version eq '2.0'),
       (*.body-blob.result eq $payload ~ $payload)]];

$encoder = HTTP::HPACK::Encoder.new;
$buf = $encoder.encode-headers(@headers);
test (Cro::HTTP2::Frame::Headers.new(
          stream-identifier => 3,
          flags => 0,
          headers => $buf.subbuf(0, 10)),
      Cro::HTTP2::Frame::Continuation.new(
          stream-identifier => 3,
          flags => 4,
          headers => $buf.subbuf(10)),
      Cro::HTTP2::Frame::Headers.new(
          stream-identifier => 5,
          flags => 5,
          headers => $encoder.encode-headers(@headers[0..3])),
      Cro::HTTP2::Frame::Data.new(
          stream-identifier => 3,
          flags => 1,
          data => $payload)),
     2, 'Header1 + Continuation1 + Header2 + Data1',
     [[(*.method eq 'POST'),
       (*.http-version eq '2.0'),
       (*.target eq '/resource')],
      [(*.method eq 'POST'),
       (*.http-version eq '2.0'),
       (*.target eq '/resource'),
       (*.body-blob.result eq $payload)]];

$encoder = HTTP::HPACK::Encoder.new;
throws-like {
    test (Cro::HTTP2::Frame::Headers.new(
                 stream-identifier => 3,
                 flags => 1,
                 headers => $encoder.encode-headers(@headers[0..3])),
          Cro::HTTP2::Frame::Headers.new(
              stream-identifier => 5,
              flags => 5,
              headers => $encoder.encode-headers(@headers[0..3])),
          Cro::HTTP2::Frame::Continuation.new(
              stream-identifier => 3,
              flags => 4,
              headers => $encoder.encode-headers(@headers[3..5]))),
         2, 'Header1 + Header2 + Continuation1',
         [[(*.method eq 'POST'),
           (*.http-version eq '2.0'),
           (*.target eq '/resource')],
          [(*.method eq 'POST'),
           (*.http-version eq '2.0'),
           (*.target eq '/resource')]], fail => True;
}, X::Cro::HTTP2::Error, 'Unfinished header cannot be interrupted';

my $p = Promise.new;
test (Cro::HTTP2::Frame::Ping.new(
             stream-identifier => 0,
             flags => 0,
             payload => 'Liberate'.encode)).List,
     0, 'Ping',
     [], test-supplies => $p;
await Promise.anyof($p, Promise.in(5));
if $p.status ~~ Kept {
    pass 'Ping is sent';
}

done-testing;
