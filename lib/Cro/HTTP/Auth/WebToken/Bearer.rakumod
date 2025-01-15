use Cro::HTTP::Auth::WebToken;

role Cro::HTTP::Auth::WebToken::Bearer does Cro::HTTP::Auth::WebToken {
    method get-token($request) {
        try {
            return $request.header('Authorization').split(' ')[1];
        }
        CATCH {
            default {
                .note;
                return Nil;
            }
        }
    }
}
