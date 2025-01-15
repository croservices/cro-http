use Cro::HTTP::Client;
use Test;

plan 2;

my $count = 8;
my $lock = Lock.new;

my $client = Cro::HTTP::Client.new(:http<2>);
my $resp = await $client.get('https://http2.akamai.com/demo');
like (await $resp.body-text), /'<html>' .* '</html>'/,
    'Single HTTP/2 request works';
await do for ^8 {
    start {
        my $resp = await $client.get('https://http2.akamai.com/demo');
        my $body = await $resp.body-text;
        if ($body ~~ /'<html>' .* '</html>'/) {
            $lock.protect({$count--});
        }
    }
}

is $count, 0, 'Parallel requests work';
