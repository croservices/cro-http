use Cro::HTTP::Client;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Cro::TLS;
use Cro;
use Test;

if supports-alpn() {
    constant $TEST_PORT = 8883;
    constant %ca := { ca-file => 't/certs-and-keys/ca-crt.pem' };
    constant %tls := {
        private-key-file => 't/certs-and-keys/server-key.pem',
        certificate-file => 't/certs-and-keys/server-crt.pem'
    };

    my $application = route {
        get -> {
            push-promise '/main.css';
            content 'text/html', "Main page";
        }
        get -> 'main.css' {
            content 'text/html', "CSS by server push!";
        }
    };

    my Cro::Service $service = Cro::HTTP::Server.new(
        :host<localhost>, :port($TEST_PORT), :$application, :http<2>, :%tls
    );
    $service.start;
    QUIT { $service.stop }

    my $client = Cro::HTTP::Client.new(:http<2>, :push-promises);

    given $client.get("https://localhost:$TEST_PORT/", :%ca) -> $resp {
        my $res = await $resp;
        my @pps;
        my @resps;
        my $get-pps = start react {
            whenever $res.push-promises -> $prom {
                push @pps, $prom;
                whenever $prom.response -> $resp {
                    push @resps, $resp;
                }
            }
        }
        await Promise.anyof($get-pps, Promise.in(10));
        is @pps.elems, 1, 'Got the expected 1 push promise';
        is @pps[0].target, '/main.css', 'Push promise had correct status';
        is @resps.elems, 1, 'Got the expected 1 response from the push promise';
        is @resps[0].status, 200, 'Correct status from response';
        is await(@resps[0].body), 'CSS by server push!', 'Correct push promise response body';
    }

    $client = Cro::HTTP::Client.new(:http<2>);
    given $client.get("https://localhost:$TEST_PORT/", :%ca) -> $resp {
        my $res = await $resp;
        my @pps;
        my $get-pps = start react {
            whenever $res.push-promises {
                push @pps, $_;
                flunk 'Got a push promise when they are disabled!';
            }
        }
        await Promise.anyof($get-pps, Promise.in(10));
        is @pps.elems, 0, 'Got zero push promises when they are disabled';
    }
} else {
    skip 'No ALPN support', 6;
}

done-testing;
