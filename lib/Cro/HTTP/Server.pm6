use Cro;
use Cro::HTTP::Internal;
use Cro::HTTP::Middleware;
use Cro::HTTP::RequestParser;
use Cro::HTTP::ResponseSerializer;
use Cro::HTTP::VersionSelector;
use Cro::HTTP2::FrameParser;
use Cro::HTTP2::FrameSerializer;
use Cro::HTTP2::RequestParser;
use Cro::HTTP2::ResponseSerializer;
use Cro::TLS;
use Cro::TCP;

my constant HTTP2-CIPHERS = 'AESGCM:HIGH:!DHE-RSA:!aNULL:!MD5';

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
                    :$host, :$port, :ssl(:tls(%tls-in)),
                    :$before-parse = (), :$before = (),
                    :$after = (), :$after-serialize = (),
                    :$add-body-parsers, :$body-parsers,
                    :$add-body-serializers, :$body-serializers,
                    :$http,
                    :$label = "HTTP($port)") {

        my @before;
        my @after;
        if $before ~~ Iterable {
            for @$before {
                when Cro::HTTP::Middleware::Pair {
                    push @before, .request;
                    unshift @after, .response;
                }
                default {
                    push @before, $_;
                }
            }
        }
        elsif $before ~~ Cro::HTTP::Middleware::Pair {
            push @before, $before.request;
            unshift @after, $before.response;
        }
        else {
            push @before, $before;
        }
        if $after ~~ Iterable {
            append @after, @$after;
        }
        else {
            push @after, $after;
        }

        my %args = :$application,
                   :$add-body-parsers, :$body-parsers,
                   :$add-body-serializers, :$body-serializers,
                   :$before-parse, :@before,
                   :@after, :$after-serialize;
        my $http-val = $http // ();

        my %tls = %tls-in;

        sub pack2(:$http2-only) {
            %tls<ciphers> ||= HTTP2-CIPHERS;
            %tls<prefer-server-ciphers> = True;
            %tls<no-compression> = True;
            %tls<no-session-resumption-on-renegotiation> = True;
            my $listener = Cro::TLS::Listener.new(|(:$host with $host), |(:$port with $port), |%tls);
            if $http2-only {
                return Cro.compose(
                    service-type => self.WHAT,
                    :$label,
                    $listener,
                    |$before-parse,
                    Cro::HTTP2::FrameParser.new,
                    Cro::HTTP2::RequestParser.new,
                    RequestParserExtension.new(:$add-body-parsers, :$body-parsers),
                    |@before,
                    $application,
                    ResponseSerializerExtension.new(:$add-body-serializers, :$body-serializers),
                    |@after,
                    Cro::HTTP2::ResponseSerializer.new(:$host, :$port),
                    Cro::HTTP2::FrameSerializer.new,
                    |$after-serialize
                )
            } else {
                return Cro.compose(
                    service-type => self.WHAT,
                    :$label,
                    $listener,
                    Cro::HTTP::VersionSelector.new(|%args)
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
                |@before,
                $application,
                ResponseSerializerExtension.new(:$add-body-serializers, :$body-serializers),
                |@after,
                Cro::HTTP::ResponseSerializer.new,
                |$after-serialize
            )
        }

        if %tls {
            if $http-val == <2> {
                die 'HTTP/2 is requested, but ALPN is not supported' unless supports-alpn;
                %tls<alpn> = <h2>;
                return pack2(:http2-only);
            } elsif $http-val eqv <1.1 2>|<2 1.1> {
                die 'HTTP/2 is requested, but ALPN is not supported' unless supports-alpn;
                %tls<alpn> = <h2 http/1.1>;
                return pack2(:!http2-only);
            } elsif $http-val eqv <1.1>|() {
                my $listener = Cro::TLS::Listener.new(
                    |(:$host with $host),
                    |(:$port with $port),
                    |%tls);
                return supports-alpn() && !$http-val ?? pack2(:!http2-only) !! pack1($listener);
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
