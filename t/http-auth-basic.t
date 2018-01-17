use Cro::HTTP::Auth::Basic;
use Cro::HTTP::Client;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Test;

constant TEST_PORT = 31318;
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

dies-ok {
    await Cro::HTTP::Client.new.get("$url/", auth => { username => 'clouds',
                                                       password => 'california'});
}, 'Wrong credentials are not passed';

throws-like {
    await Cro::HTTP::Client.new.get("$url/");
}, X::Cro::HTTP::Error::Client,
'Request without credentials returns 401';

done-testing;
