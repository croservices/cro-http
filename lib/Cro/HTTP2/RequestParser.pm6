use Cro::HTTP2::Frame;
use Cro::HTTP2::GeneralParser;
use Cro::HTTP::Internal;
use Cro::Transform;

class Cro::HTTP2::RequestParser does Cro::Transform does Cro::HTTP2::GeneralParser {
    method consumes() { Cro::HTTP2::Frame  }
    method produces() { Cro::HTTP::Request }

    submethod BUILD(:$!settings, :$!ping) {
        $!pseudo-headers = <:method :scheme :authority :path :status>;
    }

    method !get-message($http2-stream-id, $connection) {
        Cro::HTTP::Request.new(:$http2-stream-id,
                               :$connection,
                               http-version => 'http/2')
    }

    method !message-full($req--> Bool) { so $req.method && so $req.target }

    method !check-data($stream, $sid, $csid) {
        if  $sid > $csid
        ||  $stream.state !~~ data
        || !$stream.message.method
        || !$stream.message.target {
            die X::Cro::HTTP2::Error.new(code => PROTOCOL_ERROR)
        }
    }
}
