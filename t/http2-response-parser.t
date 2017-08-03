use HTTP::HPACK;
use Cro::HTTP2::ResponseParser;
use Cro::HTTP2::Frame;
use Test;

my $encoder = HTTP::HPACK::Encoder.new;
my ($buf, @headers);

sub test(@frames, $count, $desc, @checks, :$fail) {
    my ($ping, $settings);
    my $test-completed = Promise.new;
    my $parser = Cro::HTTP2::ResponseParser.new(:$ping);
    my $fake-in = Supplier.new;
    my $counter = 0;
    $parser.transformer($fake-in.Supply).tap:
    -> $response {
        for @checks[$counter].kv -> $i, $check {
            ok $check($response), "check {$i + 1}";
        }
        $counter++;
        $test-completed.keep if $counter == $count;
    },
    quit => {
        note $_;
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

@headers = HTTP::HPACK::Header.new(name => ':status', value => '302'),
           HTTP::HPACK::Header.new(name => 'etag',    value => 'xyzzy'),
           HTTP::HPACK::Header.new(name => 'expires', value => 'date');

test (Cro::HTTP2::Frame::Headers.new(
             stream-identifier => 3,
             flags => 5,
             headers => $encoder.encode-headers(@headers))).List,
     1, 'Headers',
     [[(*.status == 302),
      (*.header('etag') eq 'xyzzy'),
      (*.header('expires') eq 'date')],];
