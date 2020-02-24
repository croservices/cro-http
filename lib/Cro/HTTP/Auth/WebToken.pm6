use Cro::HTTP::Auth::WebToken::Token;
use Cro::HTTP::Middleware;
use JSON::JWT;

role Cro::HTTP::Auth::WebToken does Cro::HTTP::Middleware::Request {
    has $.secret;
    has $.public-key;
    has $.expiration = Duration.new(60 * 30);

    method process(Supply $requests --> Supply) {
        supply whenever $requests -> $req {
            my $token = self.get-token($req);
            my $auth = Nil;
            $auth = self!decode($token) if $token;

            if $auth ~~ Hash {
                with $auth<exp> {
                    $auth = Nil if Instant.from-posix($_) < now;
                }
            }
            self.set-auth($req, $auth);
            emit $req;
        }
    }

    method !decode(Str $token) {
        with $!public-key {
            return JSON::JWT.decode($token, :alg('RS256'), :pem($!public-key));
        }
        orwith $!secret {
            return JSON::JWT.decode($token, :alg('HS256'), :$!secret);
        }
        CATCH {
            default {
                .note;
                return Nil;
            }
        }
        return Nil;
    }

    method get-token($request) { ... }

    method set-auth($request, $result) {
        $request.auth = $result.defined ??
        Cro::HTTP::Auth::WebToken::Token.new(token => $result) !!
        Nil
    }
}
