use Cro::HTTP::Auth::WebToken::Bearer;
use Cro::HTTP::Client;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use JSON::JWT;
use Test;

constant TEST_PORT = 31324;
my $url = "http://localhost:{TEST_PORT}";

class MyTokenAuthBearer does Cro::HTTP::Auth::WebToken::Bearer {}

my $app = route {
    get -> Cro::HTTP::Auth $session {
        content 'text/plain', 'You are ' ~ $session.token<username>;
    }
    get -> {
        content 'text/plain', 'No token here';
    }
}

my $service = Cro::HTTP::Server.new(
    :host('localhost'), :port(TEST_PORT), application => $app,
    before => MyTokenAuthBearer.new(secret => 'Frozen Dreams')
);
$service.start;
END $service.stop();

my $time = DateTime.new(now).later(minutes=> 30).posix();
my %data = :username('Realm'), :exp($time);
my $token = JSON::JWT.encode(%data, :secret('Frozen Dreams'), :alg('HS256'));

given Cro::HTTP::Client.new -> $client {
    given await $client.get("$url/", headers => [Authorization => "Bearer $token"]) {
        is await(.body-text), 'You are Realm', 'Username is correct';
    }
}

$time = DateTime.new(now).earlier(minutes=> 30).posix();
%data = :username('Realm'), :exp($time);
$token = JSON::JWT.encode(%data, :secret('Frozen Dreams'), :alg('HS256'));

given Cro::HTTP::Client.new -> $client {
    given await $client.get("$url/", headers => [Authorization => "Bearer $token"]) {
        is await(.body-text), 'No token here', 'Expired token is not passed';
    }
}

done-testing;
