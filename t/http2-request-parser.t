use HTTP::HPACK;
use Cro::HTTP2::RequestParser;
use Cro::HTTP2::Frame;
use Cro::HTTP::Request;
use Test;

my $encoder = HTTP::HPACK::Encoder.new;
my ($buf, @headers);

sub test(@frames, $count, $desc, @checks, :$fail) {
    my $parser = Cro::HTTP2::RequestParser;
    my $fake-in = Supplier.new;
    my $test-completed = Promise.new;
    my $counter = 0;
    $parser.transformer($fake-in.Supply).tap:
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
        flunk $desc;
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
     [(*.method eq 'GET'),
     (*.target eq '/resource'),
     (*.header('Host') eq 'example.org'),
     (*.header('Accept') eq 'image/jpeg')];

$encoder = HTTP::HPACK::Encoder.new;
@headers = HTTP::HPACK::Header.new(name => ':method', value => 'POST'),
           HTTP::HPACK::Header.new(name => ':path',   value => '/resource'),
           HTTP::HPACK::Header.new(name => ':scheme', value => 'https'),
           HTTP::HPACK::Header.new(name => 'host',    value => 'example.org'),
           HTTP::HPACK::Header.new(name => 'content-type',   value => 'image/jpeg'),
           HTTP::HPACK::Header.new(name => 'content-length', value => '123'),
           HTTP::HPACK::Header.new(name => 'foo', value => 'bar');

test (Cro::HTTP2::Frame::Headers.new(
             stream-identifier => 3,
             flags => 1,
             headers => $encoder.encode-headers(@headers[0..2])),
      Cro::HTTP2::Frame::Continuation.new(
             stream-identifier => 3,
             flags => 4,
             headers => $encoder.encode-headers(@headers[3..5]))),
     1, 'Headers + Continuation',
     [(*.method eq 'POST'),
      (*.target eq '/resource'),
      (*.header('Host') eq 'example.org'),
      (*.header('Content-type')   eq 'image/jpeg'),
      (*.header('Content-length') eq '123')];

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
     [(*.method eq 'POST'),
      (*.target eq '/resource'),
      (*.body-blob.result eq $payload)];

$encoder = HTTP::HPACK::Encoder.new;
$payload = Buf.new(<0 1>.pick xx 20);
test (Cro::HTTP2::Frame::Headers.new(
             stream-identifier => 3,
             flags => 0,
             headers => $encoder.encode-headers(@headers[0..2])),
      Cro::HTTP2::Frame::Continuation.new(
             stream-identifier => 3,
             flags => 4,
             headers => $encoder.encode-headers(@headers[3..5])),
      Cro::HTTP2::Frame::Data.new(
             stream-identifier => 3,
             flags => 1,
             data => $payload)),
      1, 'Headers + Continuation + Data',
      [(*.method eq 'POST'),
       (*.target eq '/resource'),
       (*.header('Host') eq 'example.org'),
       (*.header('Content-type')   eq 'image/jpeg'),
       (*.header('Content-length') eq '123'),
       (*.body-blob.result eq $payload)];

$encoder = HTTP::HPACK::Encoder.new;
$payload = Buf.new(<0 1>.pick xx 20);
test (Cro::HTTP2::Frame::Headers.new(
             stream-identifier => 3,
             flags => 0,
             headers => $encoder.encode-headers(@headers[0..2])),
      Cro::HTTP2::Frame::Continuation.new(
             stream-identifier => 3,
             flags => 4,
             headers => $encoder.encode-headers(@headers[3..5])),
      Cro::HTTP2::Frame::Data.new(
             stream-identifier => 3,
             flags => 0,
             data => $payload),
      Cro::HTTP2::Frame::Headers.new(
             stream-identifier => 3,
             flags => 5,
             headers => $encoder.encode-headers([@headers[6]]))),
     1, 'Headers + Continuation + Data + Headers',
     [(*.method eq 'POST'),
      (*.target eq '/resource'),
      (*.header('Host') eq 'example.org'),
      (*.header('Content-type')   eq 'image/jpeg'),
      (*.header('Content-length') eq '123'),
      (*.body-blob.result eq $payload),
      (*.header('foo') eq 'bar')];

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
       (*.target eq '/resource')],
      [(*.method eq 'POST'),
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
       (*.body-blob.result eq $payload)],
      [(*.method eq 'POST'),
       (*.target eq '/resource'),
       (*.body-blob.result eq $payload ~ $payload)]];

$encoder = HTTP::HPACK::Encoder.new;
test (Cro::HTTP2::Frame::Headers.new(
          stream-identifier => 3,
          flags => 0,
          headers => $encoder.encode-headers(@headers[0..3])),
      Cro::HTTP2::Frame::Continuation.new(
          stream-identifier => 3,
          flags => 4,
          headers => $encoder.encode-headers(@headers[3..5])),
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
       (*.target eq '/resource')],
      [(*.method eq 'POST'),
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
           (*.target eq '/resource')],
          [(*.method eq 'POST'),
           (*.target eq '/resource')]], fail => True;
}, X::Cro::HTTP2::Error, 'Unfinished header cannot be interrupted';

done-testing;
