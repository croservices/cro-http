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

    get -> 'kitsune' {
        content 'text/html', 'Tail and ears';
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

{
    dies-ok { Cro::HTTP::ReverseProxy.new }, 'Cannot create ReverseProxy without target';
    dies-ok { Cro::HTTP::ReverseProxy.new(to => 'foo', to-absolute => 'bar') }, 'Cannot create ReverseProxy with double target';
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
        is await($resp.body-text), 'Home A', 'Body text from Proxy A for all requests';
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
        is await($resp.body-text), 'Home A', 'Body text from Proxy A using delegate';
    }
}

# Proxying without appending the target URL
{
    my $proxy-app = route {
        delegate <images *> => Cro::HTTP::ReverseProxy.new(:to-absolute("http://localhost:{HTTP_TEST_PORT_B}/kitsune"));
    }
    my $proxy = Cro::HTTP::Server.new(
        port => HTTP_TEST_PORT_PROXY,
        application => $proxy-app
    );
    $proxy.start;
    LEAVE $proxy.stop;

    my $c = Cro::HTTP::Client.new(base-uri => "http://localhost:{HTTP_TEST_PORT_PROXY}");
    given await $c.get('/images/base/kitsune') -> $resp {
        is await($resp.body-text), 'Tail and ears', 'Body text from Proxy B for request A';
    }
    given await $c.get('/images/base/fox') -> $resp {
        is await($resp.body-text), 'Tail and ears', 'Body text from Proxy B for request B';
    }
}

# Controlling the target URL
{
    my @servers = "http://localhost:{HTTP_TEST_PORT_A}/", "http://localhost:{HTTP_TEST_PORT_B}/";
    my $proxy-app = Cro::HTTP::ReverseProxy.new(to => { .has-header('a') ?? @servers[0] !! @servers[1] });
    my $proxy = Cro::HTTP::Server.new(port => HTTP_TEST_PORT_PROXY, application => $proxy-app);
    $proxy.start;
    LEAVE $proxy.stop;

    my $c = Cro::HTTP::Client.new(base-uri => "http://localhost:{HTTP_TEST_PORT_PROXY}");
    given await $c.get('/base') -> $resp {
        is await($resp.body-text), 'Home B', 'Body text from Proxy B from code block';
    }
    given await $c.get('/base', headers => [a => 'foo']) -> $resp {
        is await($resp.body-text), 'Home A', 'Body text from Proxy A from code block';
    }
}

{
    my $to = {
        my $p = Promise.new;
        Promise.in(1).then({ $p.keep("http://localhost:{HTTP_TEST_PORT_B}/") });
        $p;
    };
    my $proxy-app = Cro::HTTP::ReverseProxy.new(:$to);
    my $proxy = Cro::HTTP::Server.new(port => HTTP_TEST_PORT_PROXY, application => $proxy-app);
    $proxy.start;
    LEAVE $proxy.stop;

    my $c = Cro::HTTP::Client.new(base-uri => "http://localhost:{HTTP_TEST_PORT_PROXY}");
    given await $c.get('/base') -> $resp {
        is await($resp.body-text), 'Home B', 'Body text from Proxy B for Promise-like proxy URL generator';
    }
}

done-testing;
