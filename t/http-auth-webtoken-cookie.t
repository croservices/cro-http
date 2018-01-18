use Cro::HTTP::Auth::WebToken::FromCookie;
use Cro::HTTP::Client;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use JSON::JWT;
use Test;

constant TEST_PORT = 31321;
my $url = "http://localhost:{TEST_PORT}";

class MyTokenAuthCookie does Cro::HTTP::Auth::WebToken::FromCookie["_SESSION"] {}

my $app = route {
    get -> Cro::HTTP::Auth $session {
        content 'text/plain', 'You are ' ~ $session.token<username>;
    }
    get -> {
        my $time = DateTime.new(now).later(minutes=> 30).posix();
        my %data = :username('Realm'), :exp($time);
        my $token = JSON::JWT.encode(%data, :secret('Frozen Dreams'), :alg('HS256'));
        set-cookie '_SESSION', $token;
        content 'text/plain', 'No token yet';
    }
}

my $service = Cro::HTTP::Server.new(
    :host('localhost'), :port(TEST_PORT), application => $app,
    before => MyTokenAuthCookie.new(secret => 'Frozen Dreams')
);
$service.start;
END $service.stop();

my $client = Cro::HTTP::Client.new(:cookie-jar);

given $client {
    given await $client.get("$url/") {
        is await(.body-text), 'No token yet', 'Token is set to cookies';
    }
}

given $client {
    given await $client.get("$url/") {
        is await(.body-text), 'You are Realm', 'Username is correct';
    }
}

done-testing;
