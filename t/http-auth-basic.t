use Cro::HTTP::Auth::Basic;
use Cro::HTTP::Client;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Test;

constant TEST_PORT = 31321;
my $url = "http://localhost:{TEST_PORT}";

class MyUser does Cro::HTTP::Auth {
    has $.username;
}

class MyBasicAuth does Cro::HTTP::Auth::Basic[MyUser, "username"] {
    method authenticate(Str $user, Str $pass --> Bool) {
        return $user eq 'c-monster' && $pass eq 'cookiecookiecookie';
    }
}

my $app = route {
    get -> Cro::HTTP::Auth $session {
        content 'text/plain', 'You are ' ~ $session.username;
    }
    post -> Cro::HTTP::Auth $session {
        # This exists to cover a bug where a 405 got reported over a 401
        content 'text/plain', 'POST';
    }
}

my $service = Cro::HTTP::Server.new(
    :host('localhost'), :port(TEST_PORT), application => $app,
    before => MyBasicAuth.new
);
$service.start;
END $service.stop();

given Cro::HTTP::Client.new -> $client {
    given await $client.get("$url/", auth => {
                                   username => 'c-monster',
                                   password => 'cookiecookiecookie'}) {
        is await(.body-text), 'You are c-monster', 'Username is set after basic authentication';
    }
}

throws-like
        {
            await Cro::HTTP::Client.new.get: "$url/",
                    auth => { username => 'clouds', password => 'california'}
        },
        X::Cro::HTTP::Error::Client,
        response => { .status == 401 },
        '401 when wrong credentials are passed';

throws-like
        { await Cro::HTTP::Client.new.get("$url/") },
        X::Cro::HTTP::Error::Client,
        response => { .status == 401 },
        'Request without credentials returns 401';

done-testing;
