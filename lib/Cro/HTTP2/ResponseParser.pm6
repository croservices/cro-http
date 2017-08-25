use Cro::HTTP2::Frame;
use Cro::HTTP2::GeneralParser;
use Cro::Transform;

class Cro::HTTP2::ResponseParser does Cro::Transform does Cro::HTTP2::GeneralParser {
    method consumes() { Cro::HTTP2::Frame   }
    method produces() { Cro::HTTP::Response }

    submethod BUILD(:$!settings, :$!ping) {
        $!pseudo-headers = <:status>;
    }

    method !get-message($sid, $connection) {
        Cro::HTTP::Response.new(http-version => '2', http2-stream-id => $sid)
    }
    method !message-full($resp--> Bool) { so $resp.status }
    method !check-data($stream, $sid, $csid) {
        if  $sid > $csid
        ||  $stream.state !~~ data
        || !$stream.message.status {
            die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR);
        }
    }
}
