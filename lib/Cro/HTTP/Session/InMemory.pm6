use Cro::HTTP::Middleware;
use Crypt::Random::Extra;
use OO::Monitors;

# The session state lookup table is held inside of a monitor, which protects
# concurrent additions/lookups in the state store.
my monitor SessionStore {
    # We keep the session state in two ways: firstly as a lookup hash for fast
    # resolution, and secondly as a double linked list to easily trim off
    # expired sessions. Sessions are always moved to the tail of the list on
    # use, so the head of the list has those that are oldest and so may need
    # to be cleared up.
    my class Session {
        has $.key;
        has $.state;
        has Instant $.expiration is rw;
        has Session $.prev is rw;
        has Session $.next is rw;
    }

    has Duration $.expiration is required;
    has &.now is required;
    has %!session-lookup;
    has Session $!session-head;
    has Session $!session-tail;

    method lookup-session($key) {
        self!delete-expired();
        with %!session-lookup{$key} -> $session {
            self!remove-from-list($session);
            self!add-at-tail($session);
            $session.expiration = &!now() + $!expiration;
            $session.state
        }
        else {
            Nil
        }
    }

    method start-session($key, $state --> Nil) {
        self!delete-expired();
        my $session = Session.new(:$key, :$state);
        $session.expiration = &!now() + $!expiration;
        self!add-at-tail($session);
        %!session-lookup{$key} = $session;
    }

    method !delete-expired(--> Nil) {
        while $!session-head && $!session-head.expiration <= &!now() {
            %!session-lookup{$!session-head.key}:delete;
            $!session-head = $!session-head.next;
            with $!session-head {
                $!session-head.prev = Nil;
            }
        }
    }

    method !remove-from-list($session --> Nil) {
        with $session.prev {
            $session.prev.next = $session.next;
        }
        else {
            $!session-head = $session.next;
        }
        with $session.next {
            $session.next.prev = $session.prev;
        }
        else {
            $!session-tail = $session.prev;
        }
    }

    method !add-at-tail($session --> Nil) {
        $session.prev = $!session-tail;
        $session.next = Nil;
        $!session-tail = $session;
        $!session-head //= $session;
    }
}

role Cro::HTTP::Session::InMemory[::TSession] does Cro::HTTP::Middleware::RequestResponse {
    has Str $.cookie-name = toke();
    has Duration $.expiration .= new(30 * 60);
    has &.now = { now };
    has SessionStore $!store .= new(:$!expiration, :&!now);

    method process-requests(Supply $requests) {
        supply whenever $requests -> $req {
            $req.auth = self!existing-session($req) // TSession.new;
            emit $req;
        }
    }

    method !existing-session($req) {
        with $req.cookie-value($!cookie-name) {
            with $!store.lookup-session($_) {
                .return;
            }
            else {
                # We received an expired session cookie; remove it.
                $req.remove-cookie($!cookie-name);
            }
        }
        return Nil;
    }

    method process-responses(Supply $responses) {
        supply whenever $responses -> $res {
            my %cookie-opts = max-age => $!expiration, :http-only;
            with $res.request.cookie-value($!cookie-name) {
                # Already have a session cookie; put one in the response
                # with an updated expiration time (we already bumped the
                # expiration on lookup).
                $res.set-cookie($!cookie-name, $_, |%cookie-opts);
            }
            orwith $res.request.auth -> $state {
                # No cookie in the request, so it's a new session.
                my $cookie-value = toke();
                $res.set-cookie($!cookie-name, $cookie-value, |%cookie-opts);
                $!store.start-session($cookie-value, $state);
            }
            emit $res;
        }
    }

    sub toke() {
        my constant @CHARS = flat 'A'..'Z', 'a'..'z', '0'..'9';
        crypt_random_sample(@CHARS, 64).join
    }
}
