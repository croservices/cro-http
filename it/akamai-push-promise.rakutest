use Cro::HTTP::Client;
use Test;

plan 4;

my $client = Cro::HTTP::Client.new(:http<2>, :push-promises);
my $resp = await $client.get('https://http2.akamai.com/demo/h2_demo_frame_sp2.html?pushnum=5');
like (await $resp.body-text), /'<html>' .* '</html>'/,
    'Single HTTP/2 request that will have push promises works';

my $num-pps = 0;
my $num-resps = 0;
my $num-bodies = 0;
react whenever $resp.push-promises -> $pp {
    $num-pps++;
    whenever $pp.response -> $resp {
        $num-resps++;
        whenever $resp.body-blob {
            $num-bodies++;
        }
        QUIT {
            default {
                # Ignore cancelled push promises
            }
        }     
    }
}
ok $num-pps >= 5, 'Got at least expected number of push promises';
ok $num-resps >= 5, 'Got at least expected number of push promise responses';
ok $num-bodies >= 5, 'Got bodies for each of those responses';
