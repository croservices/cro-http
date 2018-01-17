use Cro::HTTP::Middleware;
use Cro::HTTP::Session::IdGenerator;

role Cro::HTTP::Session::Persistent[::TSession] does Cro::HTTP::Middleware::RequestResponse {
    has Str $.cookie-name = generate-session-id();
    has Duration $.expiration .= new(30 * 60);
    has &.now = { now };

    method create(Str $session-id) {}    
    method save(Str $session-id, TSession $session) {...}
    method load(Str $session-id --> TSession) {...}
    method clear(--> Nil) {...}

    method process-requests(Supply $requests) {
        my %cookie-opts = max-age => $!expiration, :http-only;
        supply whenever $requests -> $req {
            self.clear();
            $req.auth = TSession.new;
            my $cookie-value = $req.cookie-value($!cookie-name);
            if $cookie-value {
                try {
                    my $session = self.load($cookie-value);
                    $req.auth = $session;
                }
                CATCH {
                    $req.remove-cookie($!cookie-name);
                }
            }
            emit $req;
        }
    }

    method process-responses(Supply $responses) {
        my %cookie-opts = max-age => $!expiration, :http-only;
        supply whenever $responses -> $res {
            with $res.request.cookie-value($!cookie-name) {
                $res.set-cookie($!cookie-name, $_, |%cookie-opts);
                self.save($_, $res.request.auth);
            } orwith $res.request.auth -> $state {
                # Setting a cookie
                my $cookie-value = generate-session-id();
                $res.set-cookie($!cookie-name, $cookie-value, |%cookie-opts);
                # Callign a create;
                my $created = self.create($cookie-value);
                if $created ~~ TSession {
                    self.save($cookie-value, $created);
                } else {
                    self.save($cookie-value, $res.request.auth);
                }
            }
            emit $res;
        }
    }
}
