use Cro::HTTP::Client;
use Test;

plan 2;

my $count = 8;
my $lock = Lock.new;

my $client = Cro::HTTP::Client.new(:http<2>);
my $resp = await $client.get('https://http2.akamai.com/demo');
is (await $resp.body-text).chars, 6031, 'Single HTTP/2 request works';
await do for ^8 {
    start {
        say "New";
        my $resp = await $client.get('https://http2.akamai.com/demo');
        if (await $resp.body-text).chars == 6031 {
            say 'Bang!';
            $lock.protect({$count--});
        }
    }
}

is $count, 0, 'Parallel requests work';
