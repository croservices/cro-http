use Cro::HTTP::Client;
use Test;

plan 1;

my $resp = await Cro::HTTP::Client.get('https://specheldotcom.files.wordpress.com/2012/09/dickensian.jpg');
my $downloading = start react whenever $resp.body-byte-stream -> $blob { }
await Promise.anyof($downloading, Promise.in(60));
ok $downloading, 'Non-small download using HTTP/2 server completed';
