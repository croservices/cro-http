use Base64;
use Cro::HTTP::Middleware;
use Cro::HTTP::Auth;

role Cro::HTTP::Auth::Basic[::TSession, Str $username-prop] does Cro::HTTP::Auth does Cro::HTTP::Middleware::Request {
    method process(Supply $requests --> Supply) {
        supply whenever $requests -> $req {
            with $req.header('Authorization') {
                my $part = $_.split(' ')[1];
                with $part {
                    self!process-auth($req, $_);
                } else {
                    # Authorization header is corrupted.
                    $req.auth = Nil;
                }
            } else {
                # If no credentials are given, no auth is possible by default.
                $req.auth = Nil;
            }
            emit $req;
        }
    }

    method !process-auth($req, $auth) {
        my ($user, $pass) = decode-base64($auth, :bin).decode.split(':');
        if self.authenticate($user, $pass) {
            with $req.auth {
                $req.auth.^attributes.grep(*.name eq $username-prop)[0].set-value($user);
            } else {
                my %args = $username-prop => $user;
                $req.auth = TSession.new(|%args);
            }
        } else {
            $req.auth = Nil;
        }
    }

    method authenticate(Str $user, Str $pass --> Bool) { ... }
}

