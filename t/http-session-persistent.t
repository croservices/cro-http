use Cro::HTTP::Auth;
use Cro::HTTP::Client;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Cro::HTTP::Session::Persistent;
use OO::Monitors;
use Test;

constant TEST_PORT = 31319;
my $url = "http://localhost:{TEST_PORT}";

my $fake-now = now;

my class SessionData does Cro::HTTP::Auth {
    has $.count is rw = 0;
}
my $app = route {
    get -> SessionData $session, 'hits' {
        content 'text/plain', 'Visit ' ~ ++$session.count;
    }
}

monitor FakePersistent does Cro::HTTP::Session::Persistent[SessionData] {
    class Faker {
        has $.data;
        has $.expiration;
    }

    has %!fake-db;

    method load(Str $session-id --> SessionData) {
        with (%!fake-db{$session-id}) {
            return %!fake-db{$session-id}.data;
        }
        fail('No such session');
    }
    method create(Str $session-id) {
    }
    method save(Str $session-id, SessionData $data) {
        %!fake-db{$session-id} = Faker.new(expiration => &!now() + $!expiration, :$data);
    }
    method clear(--> Nil) {
        for %!fake-db.kv -> $key, $value {
            if $value.expiration < &!now() {
                %!fake-db{$key}:delete;
            }
        };
    }
}

my $service = Cro::HTTP::Server.new(
    :host('localhost'), :port(TEST_PORT), application => $app,
    before => FakePersistent.new(
        expiration => Duration.new(60 * 30),
        now => { $fake-now },
        cookie-name => '_session'
    )
);
$service.start;
END $service.stop();

given Cro::HTTP::Client.new -> $client {
    given await $client.get("$url/hits") {
        is await(.body-text), 'Visit 1', 'Request with no session cookie gets fresh state (1)';
    }
    given await $client.get("$url/hits") {
        is await(.body-text), 'Visit 1', 'Request with no session cookie gets fresh state (2)';
    }
}

given Cro::HTTP::Client.new(:cookie-jar) -> $client {
    for 1..5 -> $i {
        given await $client.get("$url/hits") {
            is await(.body-text), "Visit $i",
                "Session cookie being sent makes state work (request $i)";
        }
    }
}

given Cro::HTTP::Client.new(:cookie-jar) -> $client-a {
    given Cro::HTTP::Client.new(:cookie-jar) -> $client-b {
        my ($res-a, $res-b) = await do for $client-a, $client-b -> $client {
            start {
                my @a;
                for 1..5 -> $i {
                    given await $client.get("$url/hits") {
                        push @a, await(.body-text);
                    }
                }
                @a.join(',')
            }
        }
        is $res-a, 'Visit 1,Visit 2,Visit 3,Visit 4,Visit 5',
            'No session confusion with concurrent clients (A)';
        is $res-b, 'Visit 1,Visit 2,Visit 3,Visit 4,Visit 5',
            'No session confusion with concurrent clients (B)';
    }
}

given Cro::HTTP::Client.new(:cookie-jar) -> $client {
    given await $client.get("$url/hits") {
        is await(.body-text), 'Visit 1', 'New session for expiration test (sanity check)';
    }
    $fake-now += Duration.new(15 * 60);
    given await $client.get("$url/hits") {
        is await(.body-text), 'Visit 2', 'Request before expiration is OK';
    }
    $fake-now += Duration.new(15 * 60);
    given await $client.get("$url/hits") {
        is await(.body-text), 'Visit 3', 'A use of the session bumps its expiration';
    }
    $fake-now += Duration.new(31 * 60);
    given await $client.get("$url/hits") {
        is await(.body-text), 'Visit 1', 'Session expires appropriately';
    }
}

done-testing;
