use Cro;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Cro::HTTP::Client;
use Test;

constant $TEST_PORT = 8883;
constant %ca := { ca-file => 't/certs-and-keys/ca-crt.pem' };
constant %tls := {
    private-key-file => 't/certs-and-keys/server-key.pem',
    certificate-file => 't/certs-and-keys/server-crt.pem'
};

my $application = route {
    get -> {
        say "Promised";
        push-promise '/main.css';
        content 'text/html', "Main page";
    }
    get -> 'main.css' {
        say "Promise is processed";
        content 'text/html', "CSS by server push!";
    }
};

my Cro::Service $service = Cro::HTTP::Server.new(
    :host<localhost>, :port($TEST_PORT), :$application, :http<2>, :%tls
);
$service.start;
QUIT { $service.stop }

my $client = Cro::HTTP::Client.new(:http<2>);

given $client.get("https://localhost:$TEST_PORT/", :%ca) -> $resp {
    my $res = await $resp;
    say $res;
}

done-testing;
