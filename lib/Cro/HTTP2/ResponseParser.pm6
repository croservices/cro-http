use Cro::HTTP2::GeneralParser;
use Cro::Transform;

class Cro::HTTP2::ResponseParser does Cro::Transform does Cro::HTTP2::GeneralParser {
    method consumes() { Cro::HTTP2::Frame   }
    method produces() { Cro::HTTP::Response }

    submethod BUILD(:$!settings, :$!ping) {
        $!pseudo-headers = <:status>;
    }

    method !get-message($sid) { Cro::HTTP::Response.new(http-version => 'http/2') }
    method !message-full($resp--> Bool) { so $resp.status }
}
