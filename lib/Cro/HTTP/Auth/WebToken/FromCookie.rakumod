use Cro::HTTP::Auth::WebToken;

role Cro::HTTP::Auth::WebToken::FromCookie[Str $cookie-name] does Cro::HTTP::Auth::WebToken {
    method get-token($request) {
        $request.cookie-value($cookie-name);
    }
}
