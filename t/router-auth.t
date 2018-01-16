use Cro;
use Cro::HTTP::Auth;
use Cro::HTTP::Request;
use Cro::HTTP::Router;
use Test;

sub body-text(Cro::HTTP::Response $r) {
    $r.body-byte-stream.list.map(*.decode('utf-8')).join
}

{
    my class TestAuth does Cro::HTTP::Auth {
        has $.logged-in = False;
        has $.admin = False;
        method test(TestAuth:D:) { "auth object" }
    }
    my subset LoggedIn of TestAuth where .logged-in;
    my subset Admin of TestAuth where .admin;

    my $test-auth;
    my $app = route -> {
        before { .auth = $test-auth }

        delegate (*,) => route {
            get -> TestAuth $user {
                content 'text/plain', $user.test();
            }

            get -> LoggedIn $user, 'page' {
                content 'text/plain', 'Logged in user only here';
            }

            get -> Admin $user, 'admin' {
                content 'text/plain', 'Admin user only here';
            }
        }
    }
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    $test-auth = TestAuth.new(:!logged-in, :!admin);
    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</>));
    given $responses.receive -> $r {
        is $r.status, '200', 'Can request / successfully with non-logged-in, non-admin';
        is body-text($r), 'auth object', 'Get the authorization object';
    }
    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</page>));
    given $responses.receive -> $r {
        is $r.status, '401', 'Request to /page when not logged in is 401';
    }
    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</admin>));
    given $responses.receive -> $r {
        is $r.status, '401', 'Request to /admin when not logged in is 401';
    }

    $test-auth = TestAuth.new(:logged-in, :!admin);
    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</>));
    given $responses.receive -> $r {
        is $r.status, '200', 'Can request / successfully with logged-in, non-admin';
        is body-text($r), 'auth object', 'Get the authorization object';
    }
    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</page>));
    given $responses.receive -> $r {
        is $r.status, '200', 'Can request /page successfully with logged-in, non-admin';
        is body-text($r), 'Logged in user only here', 'Got expected body';
    }
    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</admin>));
    given $responses.receive -> $r {
        is $r.status, '401', 'Request to /admin when not an admin is 401';
    }

    $test-auth = TestAuth.new(:logged-in, :admin);
    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</>));
    given $responses.receive -> $r {
        is $r.status, '200', 'Can request / successfully with logged-in admin';
        is body-text($r), 'auth object', 'Get the authorization object';
    }
    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</page>));
    given $responses.receive -> $r {
        is $r.status, '200', 'Can request /page successfully with logged-in admin';
        is body-text($r), 'Logged in user only here', 'Got expected body';
    }
    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</admin>));
    given $responses.receive -> $r {
        is $r.status, '200', 'Can request /admin successfully with logged-in admin';
        is body-text($r), 'Admin user only here', 'Got expected body';
    }
}

done-testing;
