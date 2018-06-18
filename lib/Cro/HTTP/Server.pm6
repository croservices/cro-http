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

# Use Mozilla "Modern Compatibility" ciphers by default
# See: https://wiki.mozilla.org/Security/Server_Side_TLS#Modern_compatibility
my constant HTTP2-CIPHERS = 'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256';

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
                    :$http, :@allowed-methods,
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
                    @allowed-methods.elems == 0 ?? Cro::HTTP2::RequestParser.new !! Cro::HTTP2::RequestParser.new(:@allowed-methods),
                    RequestParserExtension.new(:$add-body-parsers, :$body-parsers),
                    |@before,
                    $application,
                    ResponseSerializerExtension.new(:$add-body-serializers, :$body-serializers),
                    |@after,
                    Cro::HTTP2::ResponseSerializer.new(
                        |(:$host with $host),
                        |(:$port with $port)
                    ),
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
                @allowed-methods.elems == 0 ?? Cro::HTTP::RequestParser.new !! Cro::HTTP::RequestParser.new(:@allowed-methods),
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
