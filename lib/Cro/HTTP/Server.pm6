use Cro;
use Cro::HTTP::Internal;
use Cro::HTTP::RequestParser;
use Cro::HTTP::ResponseSerializer;
use Cro::HTTP2::FrameParser;
use Cro::HTTP2::FrameSerializer;
use Cro::HTTP2::RequestParser;
use Cro::HTTP2::ResponseSerializer;
use Cro::SSL;
use Cro::TCP;

my class RequestParserExtension is ParserExtension {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Request }
}

my class ResponseSerializerExtension is SerializerExtension {
    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::HTTP::Response }
}

class Cro::HTTP::Server does Cro::Service {
    method !convert-middleware($middle) {
        $middle ~~ Iterable ?? $middle.List !! ($middle === Any ?? () !! $middle)
    }

    only method new(Cro::Transform :$application!,
                    :$host, :$port, :%ssl,
                    :$before-parse = (), :$before = (),
                    :$after = (), :$after-serialize = (),
                    :$add-body-parsers, :$body-parsers,
                    :$add-body-serializers, :$body-serializers,
                    :$http,
                    :$label = "HTTP($port)") {

        my %args = :$application,
                   :$add-body-parsers, :$body-parsers,
                   :$add-body-serializers, :$body-serializers,
                   :$before-parse, :$before,
                   :$after, :$after-serialize;
        my $http-val = $http ?? $http !! ();

        sub pack2(:$http2-only) {
            my $listener = Cro::SSL::Listener.new(|(:$host with $host), |(:$port with $port), |%ssl);
            if $http2-only {
                return Cro.compose(
                    service-type => self.WHAT,
                    :$label,
                    $listener,
                    |$before-parse,
                    Cro::HTTP2::FrameParser,
                    Cro::HTTP2::RequestParser.new,
                    RequestParserExtension.new(:$add-body-parsers, :$body-parsers),
                    |$before,
                    $application,
                    ResponseSerializerExtension.new(:$add-body-serializers, :$body-serializers),
                    |$after,
                    Cro::HTTP2::ResponseSerializer.new,
                    Cro::HTTP2::FrameSerializer,
                    |$after-serialize
                )
            } else {
                return Cro.compose(
                    service-type => self.WHAT,
                    :$label,
                    $listener,
                    Cro::HTTP2::VersionSelector(|%args)
                )
            }
        }

        sub pack1($listener) {
            Cro.compose(
                service-type => self.WHAT,
                :$label,
                $listener,
                |$before-parse,
                Cro::HTTP::RequestParser.new,
                RequestParserExtension.new(:$add-body-parsers, :$body-parsers),
                |$before,
                $application,
                ResponseSerializerExtension.new(:$add-body-serializers, :$body-serializers),
                |$after,
                Cro::HTTP::ResponseSerializer.new,
                |$after-serialize
            )
        }

        if %ssl {
            if $http-val == <2> {
                die 'HTTP?2 is requested, but ALPN is not supported' unless supports-alpn;
                %ssl<alpn> = <h2>;
                return pack2(:http2-only);
            } elsif $http-val == <1.1 2> {
                die 'HTTP?2 is requested, but ALPN is not supported' unless supports-alpn;
                %ssl<alpn> = <h2 http/1.1>;
                return pack2(:!http2-only);
            } elsif so $http-val == <1.1>|() {
                %ssl<alpn> = supports-alpn() ?? <h2 http/1.1> !! <http/1.1>;
                my $listener = Cro::SSL::Listener.new(
                    |(:$host with $host),
                    |(:$port with $port),
                    |%ssl);
                return pack1($listener);
            } else {
                die "Incorrect :$http parameter was passed to the server: $http-val"
            }
        }
        else {
            if so $http-val == <1.1>|() {
                my $listener = Cro::TCP::Listener.new(
                    |(:$host with $host),
                    |(:$port with $port));
                return pack1($listener);
            } else {
                die "Incorrect :\$http parameter was passed to the server: $http-val"
            }
        }
    }
}
