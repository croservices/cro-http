use Cro::HTTP::Client;
use Cro::HTTP::ReverseProxy;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Test;

plan *;

constant HTTP_TEST_PORT_PROXY = 31323;
constant HTTPS_TEST_PORT_PROXY = 31325;

constant HTTP_TEST_PORT_A = 31319;
constant HTTPS_TEST_PORT_A = 31320;
constant HTTP_TEST_PORT_B = 31321;
constant HTTPS_TEST_PORT_B = 31322;
constant %ca := { ca-file => 't/certs-and-keys/ca-crt.pem' };
constant %key-cert := {
    private-key-file => 't/certs-and-keys/server-key.pem',
    certificate-file => 't/certs-and-keys/server-crt.pem'
};

my $app-a = route {
    get -> 'base' {
        content 'text/html', 'Home A';
    }
}

my $app-b = route {
    get -> 'base' {
        content 'text/html', 'Home B';
    }
}

my $server-a = Cro::HTTP::Server.new(port => HTTP_TEST_PORT_A, application => $app-a);
my $server-as = Cro::HTTP::Server.new(port => HTTPS_TEST_PORT_A, application => $app-a, tls => %key-cert, :http<2>);
my $server-b = Cro::HTTP::Server.new(port => HTTP_TEST_PORT_B, application => $app-b);
my $server-bs = Cro::HTTP::Server.new(port => HTTPS_TEST_PORT_B, application => $app-b, tls => %key-cert, :http<2>);
$server-a.start;
$server-as.start;
$server-b.start;
$server-bs.start;

END {
    $server-a.stop;
    $server-as.stop;
    $server-b.stop;
    $server-bs.stop;
}

# Proxying all incoming requests
{
    my $proxy-app = Cro::HTTP::ReverseProxy.new(to => "http://localhost:{HTTP_TEST_PORT_A}/");
    my $proxy = Cro::HTTP::Server.new(
        port => HTTP_TEST_PORT_PROXY,
        application => $proxy-app
    );
    $proxy.start;
    LEAVE $proxy.stop;

    my $c = Cro::HTTP::Client.new(base-uri => "http://localhost:{HTTP_TEST_PORT_PROXY}");
    given await $c.get('/base') -> $resp {
        is await($resp.body-text), 'Home A', 'Body text from Proxy A';
    }
}

# Proxying just some routes
{
    my $proxy-app = route {
        delegate <user *> => Cro::HTTP::ReverseProxy.new(to => "http://localhost:{HTTP_TEST_PORT_A}/");
    }
    my $proxy = Cro::HTTP::Server.new(
        port => HTTP_TEST_PORT_PROXY,
        application => $proxy-app
    );
    $proxy.start;
    LEAVE $proxy.stop;

    my $c = Cro::HTTP::Client.new(base-uri => "http://localhost:{HTTP_TEST_PORT_PROXY}");
    given await $c.get('/user/base') -> $resp {
        is await($resp.body-text), 'Home A', 'Body text from Proxy A';
    }
}

done-testing;
