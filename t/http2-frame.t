use Cro::HTTP2::Frame;
use Test;

dies-ok { Cro::HTTP2::Frame::Data.new(
                flags => 0, stream-identifier => 0,
                data => 'test'.encode) }, 'DATA frame stream identifier cannot be 0';

dies-ok { Cro::HTTP2::Frame::Headers.new(
                flags => 0, stream-identifier => 0,
                data => 'test'.encode) }, 'HEADERS frame stream identifier cannot be 0';

dies-ok { Cro::HTTP2::Frame::Priority.new(
                flags => 0, stream-identifier => 0,
                dependency => 4, weight => 64, exclusive => True) },
        'PRIORITY frame stream identifier cannot be 0';

dies-ok { Cro::HTTP2::Frame::Settings.new(
                flags => 1,
                stream-identifier => 30,
                ()) },
    'Settings stream-identifier cannot be non-zero';

dies-ok { Cro::HTTP2::Frame::PushPromise.new(
                flags => 0, stream-identifier => 0,
                promised-sid => 4, headers => 'header'.encode) },
        'PUSH_PROMISE frame stream identifier cannot be 0';

dies-ok { Cro::HTTP2::Frame::Ping.new(
                flags => 1, stream-identifier => 30,
                payload => Blob.new) },
    'Ping stream-identifier cannot be non-zero';

dies-ok { Cro::HTTP2::Frame::Goaway.new(
                flags => 1, stream-identifier => 30,
                last-sid => 64, error-code => 0, payload => Blob.new) },
    'GOAWAY Frame stream-identifier cannot be non-zero';

done-testing;
