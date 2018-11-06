use Cro::HTTP::Client;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Cro::HTTP::Session::InMemory;
use Cro::TLS;
use Test;

if supports-alpn() {
    constant TEST_PORT = 31290;
    my $base = "https://localhost:{TEST_PORT}";
    constant %ca := { ca-file => 't/certs-and-keys/ca-crt.pem' };
    constant %key-cert := {
        private-key-file => 't/certs-and-keys/server-key.pem',
        certificate-file => 't/certs-and-keys/server-crt.pem'
    };

    my class UserSession does Cro::HTTP::Auth {
        has $.username is rw;

        method logged-in() {
            $!username.defined;
        }
    }

    my $application = route {
        post -> {
            request-body -> (:$foo, *%) {
                content 'text/html', "Answer";
            }
        }

        get -> UserSession $s {
            content 'text/html', "{$s.logged-in ?? $s.username !! '-'}";
        }

        post -> Cro::HTTP::Auth $user, 'login' {
            request-body -> (:$username, *%) {
                $user.username = $username;
                content 'text/html', $username;
            }
        }
    }

    my Cro::Service $http = Cro::HTTP::Server.new:
    http => <2>, port => TEST_PORT, tls => %key-cert, :$application,
    before => Cro::HTTP::Session::InMemory[UserSession].new(
        expiration => Duration.new(60 * 15),
        cookie-name => 'my_session_cookie_name');

    $http.start;
    END $http.stop;

    given await Cro::HTTP::Client.post("$base/", :%ca,
                                       content-type => 'application/x-www-form-urlencoded',
                                       body => foo => 42) -> $resp {
        is await($resp.body-text), 'Answer', 'HTTP/2 server can parse body';
    };

    my $cookie-jar = Cro::HTTP::Client::CookieJar.new;

    my $auth-c = Cro::HTTP::Client.new(:$cookie-jar, :%ca);
    given await $auth-c.post("$base/login",
                             content-type => 'application/x-www-form-urlencoded',
                             body => username => 'Name') -> $resp {
        is await($resp.body-text), 'Name', 'HTTP/2 server gets Auth set';
    }

    given await $auth-c.get("$base/", cookies => (foo => 'bar')) -> $resp {
        is await($resp.body-text), 'Name', 'HTTP/2 server preserves Auth data';
    }

} else {
    skip 'No ALPN support', 1;
}

done-testing;
