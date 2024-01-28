use v6.d;
use Base64;
use OO::Monitors;
use Cro::Policy::Timeout;
use Cro::HTTP::Client::CookieJar;
use Cro::HTTP::Internal;
use Cro::HTTP::Exception;
use Cro::HTTP::Header;
use Cro::HTTP::LogTimelineSchema;
use Cro::HTTP::Request;
use Cro::HTTP::RequestSerializer;
use Cro::HTTP::ResponseParser;
use Cro::HTTP2::Frame;
use Cro::HTTP2::FrameParser;
use Cro::HTTP2::FrameSerializer;
use Cro::HTTP2::RequestSerializer;
use Cro::HTTP2::ResponseParser;
use Cro::HTTP2::GeneralParser;
use Cro::TCP;
use Cro::TLS;
use Cro::Uri;
use Cro::Iri;
use Cro::Iri::HTTP;
use Cro;

my class ResponseParserExtension is ParserExtension {
    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::HTTP::Response }
}

my class RequestSerializerExtension is SerializerExtension {
    method consumes() { Cro::HTTP::Request }
    method produces() { Cro::HTTP::Request }
}

#| Thrown by the HTTP client when a request results in an unsuccessful response
class X::Cro::HTTP::Error is Exception {
    #| The response object of the unsuccessful request
    has Cro::HTTP::Response $.response;

    #| The response phrase in the HTTP response
    method message() {
        "{$.response.get-response-phrase} ($.request.method() $.request.uri())"
    }

    #| The request that resulted in the unsuccessful response.
    method request(--> Cro::HTTP::Request) {
        $!response.request
    }
}

#| Thrown by the HTTP client when it receives a response indicating a client
#| error (4xx response code)
class X::Cro::HTTP::Error::Client is X::Cro::HTTP::Error {}

#| Thrown by the HTTP client when it receives a response indicating a server
#| error (5xx response code)
class X::Cro::HTTP::Error::Server is X::Cro::HTTP::Error {}

class X::Cro::HTTP::Client::BodyAlreadySet is Exception {
    method message() {
        "Body was set twice"
    }
}

class X::Cro::HTTP::Client::IncorrectHeaderType is Exception {
    has $.what;

    method message() {
        "Incorrect header of type {$.what.^name} was passed to HTTP client"
    }
}

#| Thrown if the number of redirects resulting from a HTTP request exceeds the
#| redirect limit (often indicates a redirect loop)
class X::Cro::HTTP::Client::TooManyRedirects is Exception {
    method message() {
        "Too many redirects"
    }
}

class X::Cro::HTTP::Client::InvalidAuth is Exception {
    has $.reason;
    method message() {
        "Authentication failed: {$!reason}"
    }
}

class X::Cro::HTTP::Client::InvalidVersion is Exception {
    method message() {
        "Invalid HTTP version argument (may be :http<1.1>, :http<2>, or :http<1.1 2>)"
    }
}

class X::Cro::HTTP::Client::InvalidCookie is Exception {
    has $.bad;
    method message() {
        "Cannot add $!bad.^name() as a cookie (expected a hash of keys to values, " ~
        "or a list of Pair and Cro::HTTP::Cookie objects)"
    }
}

class X::Cro::HTTP::Client::InvalidTimeoutFormat is Exception {
    has $.bad;
    method message() {
        "Cannot set $!bad.^name() as a timeout (expected a Map of phases or a Real value or an object doing Cro::Policy::Timeout)"
    }
}

class Cro::HTTP::Client::Policy::Timeout does Cro::Policy::Timeout[%(
    connection => 60,
    headers => 60,
    body => Inf,
    total => Inf)] {
}

#| A HTTP client. Can be used by calling methods on the type object, or by making an
#| instance of the client. An instance can maintain a pool of connections to re-use
#| for multiple requests, as well as allowing configuration of common properties of
#| many requests at construction time.
class Cro::HTTP::Client {
    my class PipelineClosedBeforeHeaders is Exception { }
    my class Pipeline {
        has Bool $.secure;
        has Str $.host;
        has Int $.port;
        has Supplier $!in;
        has Tap $!tap;
        has $!next-response-vow;
        has Bool $.dead = False;
        has Lock::Async $!lock .= new;

        submethod BUILD(:$!secure!, :$!host!, :$!port!, :$!in!, :$out!) {
            $!tap = supply {
                whenever $out {
                    my $vow = $!next-response-vow;
                    $!next-response-vow = Nil;
                    $vow.keep($_);
                    LAST {
                        $!dead = True;
                        $!lock.protect: {
                            if $!next-response-vow {
                                $!next-response-vow.break:
                                    PipelineClosedBeforeHeaders.new;
                                $!next-response-vow = Nil;
                            }
                        }
                    }
                    QUIT {
                        default {
                            $!dead = True;
                            $!lock.protect: {
                                if $!next-response-vow {
                                    $!next-response-vow.break($_);
                                    $!next-response-vow = Nil;
                                }
                            }
                        }
                    }
                }
            }.tap
        }

        method send-request($request --> Promise) {
            my $next-response-promise;
            my $broken = False;
            $!lock.protect: {
                if $!dead {
                    # Without https://github.com/MoarVM/MoarVM/pull/1782 merged,
                    # we can't put the below return here.
                    $broken = True;
                }
                else {
                    $next-response-promise = Promise.new;
                    $!next-response-vow = $next-response-promise.vow;
                }
            }
            return Promise.broken(PipelineClosedBeforeHeaders.new) if $broken;

            $!in.emit($request);
            return $next-response-promise;
        }

        method close() { $!in.done }
    }

    my class GoAwayRetry is Exception {
        has $.goaway-exception;
    }

    my class Pipeline2 {
        has Lock $!lock = Lock.new;
        has Bool $.secure;
        has Str $.host;
        has Int $.port;
        has Supplier $!in;
        has Tap $!tap;
        has Bool $.dead = False;
        has $!next-stream-id = 1;
        has %!outstanding-stream-responses{Int};

        submethod BUILD(:$!secure!, :$!host!, :$!port!, :$!in!, :$out!) {

            $!tap = supply {
                whenever $out -> $response {
                    self.response($response);
                    LAST {
                        $!dead = True;
                        self.break-all-responses(X::AdHoc.new(message => 'Connection to server lost'));
                    }
                    QUIT {
                        when X::Cro::HTTP2::GoAway {
                            $!dead = True;
                            $!lock.protect: {
                                for %!outstanding-stream-responses.kv -> $sid, $vow {
                                    if $sid > .last-processed-sid {
                                        %!outstanding-stream-responses{$sid}:delete;
                                        if .code == NO_ERROR {
                                            $vow.break(GoAwayRetry.new(goaway-exception => $_));
                                        }
                                        else {
                                            $vow.break($_);
                                        }
                                    }
                                }
                            }
                        }
                        default {
                            $!dead = True;
                            self.break-all-responses($_);
                        }
                    }
                }
            }.tap
        }

        method send-request(Cro::HTTP::Request $request --> Promise) {
            my $p = Promise.new;
            my $broken = False;
            $!lock.protect: {
                if $!dead {
                    # Without https://github.com/MoarVM/MoarVM/pull/1782 merged,
                    # we can't put the below return here.
                    $broken = True;
                }
                else {
                    my $stream-id = $!next-stream-id;
                    $!next-stream-id += 2;
                    $request.http2-stream-id = $stream-id;
                    $request.http-version = '2.0';
                    %!outstanding-stream-responses{$stream-id} = $p.vow;
                }
            }
            return Promise.broken(PipelineClosedBeforeHeaders.new) if $broken;
            $!in.emit($request);
            $p
        }

        method response($response) {
            my $vow = $!lock.protect: {
                %!outstanding-stream-responses{$response.http2-stream-id}:delete
            }
            $vow.keep($response);
        }

        method break-all-responses($error) {
            $!lock.protect: {
                for %!outstanding-stream-responses.values -> $vow {
                    $vow.break($error);
                }
                %!outstanding-stream-responses = ();
            }
        }

        method close() { $!in.done }
    }

    my monitor ConnectionCache {
        has %!cached-http1;
        has %!cached-http2;

        method pipeline-for($secure, $host, $port, $http) {
            my $key = self!key($secure, $host, $port);
            if $http eq '2' || !$http && $secure {
                if %!cached-http2{$key} -> $pipeline {
                    if $pipeline.dead {
                        %!cached-http2{$key}:delete;
                        return Nil;
                    }
                    else {
                        return $pipeline;
                    }
                }
            }
            if $http ne '1.1' && %!cached-http1{$key} -> @available {
                while @available {
                    my $pipeline = @available.shift;
                    return $pipeline unless $pipeline.dead;
                }
            }
            Nil
        }

        method add-pipeline($pipeline --> Nil) {
            with $pipeline {
                unless .dead {
                    when Pipeline2 {
                        %!cached-http2{self!key(.secure, .host, .port)} = $pipeline;
                    }
                    default {
                        push %!cached-http1{self!key(.secure, .host, .port)}, $pipeline;
                    }
                }
            }
        }

        method !key($secure, $host, $port) {
            "{$secure ?? 'https' !! 'http'}\0$host\0$port"
        }
    }

    #| Headers that are added to every request by default
    has @.headers;

    #| The cookie jar that the HTTP client uses to store cookies
    has $.cookie-jar;

    #| A replacement set of body serializers, completely overriding the defaults
    has $.body-serializers;

    #| Body serializers added to the default set, or to body-serializers
    has $.add-body-serializers;

    #| A replacement set of body parsers, completely overriding the defaults
    has $.body-parsers;

    #| Body parsers added to the default set, or to body-parsers
    has $.add-body-parsers;

    #| The default content type set on a request
    has $.content-type;

    #| The maximum number of redirects that will be followed
    has $.follow;

    #| The allowed HTTP version(s) (the string '1.1, '2.0', or a List with
    #| both)
    has $.http;

    #| The certificate authority to use for verifying TLS certificates
    has $.ca;

    #| The base URI, which will be prepended to all URIs of requests using
    #| URI reference rules (meaning that an absolute URL passed to a
    #| request method with override this completely)
    has Cro::Uri $.base-uri;

    #| Options to be passed on to IO::Socket::Async::SSL.
    has %.tls;

    #| Whether push promises are accepted by the client
    has $.push-promises;

    #| User agent header value
    has $.user-agent;

    #| Authorization configuration as a hash, which should either be empty,
    #| container username and password keys for basic authentication, or
    #| contain the bearer key for bearer authentication
    has %.auth;

    #| The Proxy URL for a HTTP request.
    has Cro::Uri $.http-proxy;

    #| The Proxy URL for a HTTPS request.
    has Cro::Uri $.https-proxy;

    #| Request timeout policy.
    has Cro::Policy::Timeout $.timeout-policy;

    #| How often should we retry to send a request when the server answered
    #| with a NO_ERROR GoAway packet?
    has $.http2-goaway-retries;

    has $!persistent;
    has $!connection-cache = ConnectionCache.new;

    #| Tests if the HTTP client will use persistent connections, or make one
    #| connection per request. On the type object, it will always return False,
    #| since an instance of the client is required for persistent connections.
    method persistent(--> Bool) {
        self ?? $!persistent !! False
    }

    my constant $DEFAULT-MAX-REDIRECTS = 5;

    submethod BUILD(:$cookie-jar, :@!headers, :$!content-type, :$base-uri,
                    :$!body-serializers, :$!add-body-serializers,
                    :$!body-parsers, :$!add-body-parsers,
                    :$http-proxy, :$https-proxy,
                    :$!follow = $DEFAULT-MAX-REDIRECTS, :%!auth, :$!http,
                    :$!persistent = True, :$!ca, :$!push-promises = False,
                    :ssl(:%!tls), :$timeout, :$!http2-goaway-retries = 1,
                    :$!user-agent = 'Cro') {
        if $cookie-jar ~~ Bool {
            $!cookie-jar = Cro::HTTP::Client::CookieJar.new;
        }
        elsif $cookie-jar ~~ Cro::HTTP::Client::CookieJar {
            $!cookie-jar = $cookie-jar;
        }
        if (%!auth<username>:exists) && (%!auth<password>:exists) {
            if %!auth<bearer>:exists {
                my $reason = 'Both basic and bearer authentication methods cannot be used';
                die X::Cro::HTTP::Client::InvalidAuth.new(:$reason);
            }
        }
        with $!http {
            unless $_ eq '1.1' || $_ eq '2' || $_ eqv <1.1 2> {
                die X::Cro::HTTP::Client::InvalidVersion.new;
            }
        }
        if $timeout {
            calculate-timeout($timeout, $!timeout-policy);
        }

        $!base-uri = self!wrap-uri($_) with $base-uri;
        $!http-proxy = self!wrap-uri($_) with $http-proxy;
        $!https-proxy = self!wrap-uri($_) with $https-proxy;
    }

    method !wrap-uri($uri) {
        with $uri {
            when Cro::Uri { $uri; }
            when Cro::Iri { $uri.to-uri; }
            default { Cro::Iri::HTTP.parse(~$uri).to-uri; }
        }
    }

    #| Make a HTTP GET request to the specified URL. Returns a C<Promise>
    #| that will be kept with a C<Cro::HTTP::Response> if the request is
    #| successful.
    multi method get($url, %options --> Promise) {
        self.request('GET', $url, %options)
    }

    #| Make a HTTP GET request to the specified URL. Returns a C<Promise>
    #| that will be kept with a C<Cro::HTTP::Response> if the request is
    #| successful.
    multi method get($url, *%options --> Promise) {
        self.request('GET', $url, %options)
    }

    #| Make a HTTP GET request to the specified URL. Returns a C<Promise>
    #| that will be kept with the response body if the request is successful.
    multi method get-body($url, %options --> Promise) {
        self.request-body('GET', $url, %options)
    }

    #| Make a HTTP GET request to the specified URL. Returns a C<Promise>
    #| that will be kept with the response body if the request is successful.
    multi method get-body($url, *%options --> Promise) {
        self.request-body('GET', $url, %options)
    }

    #| Make a HTTP HEAD request to the specified URL. Returns a C<Promise>
    #| that will be kept with a C<Cro::HTTP::Response> if the request is
    #| successful.
    multi method head($url, %options --> Promise) {
        self.request('HEAD', $url, %options)
    }

    #| Make a HTTP HEAD request to the specified URL. Returns a C<Promise>
    #| that will be kept with a C<Cro::HTTP::Response> if the request is
    #| successful.
    multi method head($url, *%options --> Promise) {
        self.request('HEAD', $url, %options)
    }

    #| Make a HTTP POST request to the specified URL. Returns a C<Promise>
    #| that will be kept with a C<Cro::HTTP::Response> if the request is
    #| successful.
    multi method post($url, %options --> Promise) {
        self.request('POST', $url, %options)
    }

    #| Make a HTTP POST request to the specified URL. Returns a C<Promise>
    #| that will be kept with a C<Cro::HTTP::Response> if the request is
    #| successful.
    multi method post($url, *%options --> Promise) {
        self.request('POST', $url, %options)
    }

    #| Make a HTTP POST request to the specified URL. Returns a C<Promise>
    #| that will be kept with the response body if the request is successful.
    multi method post-body($url, %options --> Promise) {
        self.request-body('POST', $url, %options)
    }

    #| Make a HTTP POST request to the specified URL. Returns a C<Promise>
    #| that will be kept with the response body if the request is successful.
    multi method post-body($url, *%options --> Promise) {
        self.request-body('POST', $url, %options)
    }

    #| Make a HTTP PUT request to the specified URL. Returns a C<Promise>
    #| that will be kept with a C<Cro::HTTP::Response> if the request is
    #| successful.
    multi method put($url, %options --> Promise) {
        self.request('PUT', $url, %options)
    }

    #| Make a HTTP PUT request to the specified URL. Returns a C<Promise>
    #| that will be kept with a C<Cro::HTTP::Response> if the request is
    #| successful.
    multi method put($url, *%options --> Promise) {
        self.request('PUT', $url, %options)
    }

    #| Make a HTTP PUT request to the specified URL. Returns a C<Promise>
    #| that will be kept with the response body if the request is successful.
    multi method put-body($url, %options --> Promise) {
        self.request-body('PUT', $url, %options)
    }

    #| Make a HTTP PUT request to the specified URL. Returns a C<Promise>
    #| that will be kept with the response body if the request is successful.
    multi method put-body($url, *%options --> Promise) {
        self.request-body('PUT', $url, %options)
    }

    #| Make a HTTP DELETE request to the specified URL. Returns a C<Promise>
    #| that will be kept with a C<Cro::HTTP::Response> if the request is
    #| successful.
    multi method delete($url, %options --> Promise) {
        self.request('DELETE', $url, %options)
    }

    #| Make a HTTP DELETE request to the specified URL. Returns a C<Promise>
    #| that will be kept with a C<Cro::HTTP::Response> if the request is
    #| successful.
    multi method delete($url, *%options --> Promise) {
        self.request('DELETE', $url, %options)
    }

    #| Make a HTTP DELETE request to the specified URL. Returns a C<Promise>
    #| that will be kept with the response body if the request is successful.
    multi method delete-body($url, %options --> Promise) {
        self.request-body('DELETE', $url, %options)
    }

    #| Make a HTTP DELETE request to the specified URL. Returns a C<Promise>
    #| that will be kept with the response body if the request is successful.
    multi method delete-body($url, *%options --> Promise) {
        self.request-body('DELETE', $url, %options)
    }

    #| Make a HTTP PATCH request to the specified URL. Returns a C<Promise>
    #| that will be kept with a C<Cro::HTTP::Response> if the request is
    #| successful.
    multi method patch($url, %options --> Promise) {
        self.request('PATCH', $url, %options)
    }

    #| Make a HTTP PATCH request to the specified URL. Returns a C<Promise>
    #| that will be kept with a C<Cro::HTTP::Response> if the request is
    #| successful.
    multi method patch($url, *%options --> Promise) {
        self.request('PATCH', $url, %options)
    }

    #| Make a HTTP PATCH request to the specified URL. Returns a C<Promise>
    #| that will be kept with the response body if the request is successful.
    multi method patch-body($url, %options --> Promise) {
        self.request-body('PATCH', $url, %options)
    }

    #| Make a HTTP PATCH request to the specified URL. Returns a C<Promise>
    #| that will be kept with the response body if the request is successful.
    multi method patch-body($url, *%options --> Promise) {
        self.request-body('PATCH', $url, %options)
    }

    #| Make a HTTP request, specifying the HTTP method (GET, POST, etc.),
    #| the URL, and any further request options. Returns a C<Promise> that
    #| will be kept with a C<Cro::HTTP::Response> if the request is
    #| successful.
    multi method request(Str $method, $url, *%options --> Promise) {
        self.request($method, $url, %options)
    }

    #| Make a HTTP request, specifying the HTTP method (GET, POST, etc.),
    #| the URL, and any further request options. Returns a C<Promise> that
    #| will be kept with a C<Cro::HTTP::Response> if the request is
    #| successful.
    multi method request(Str $method, $url, %options --> Promise) {
        my $parent = %options<PARENT-REQUEST-LOG>;
        my $request-log = $parent
                ?? Cro::HTTP::LogTimeline::Request.start($parent, :$method, :url(~$url))
                !! Cro::HTTP::LogTimeline::Request.start(:$method, :url(~$url));
        CATCH { $request-log.end }

        my $parsed-url = self && $!base-uri
            ?? $!base-uri.add($url)
            !! self!wrap-uri($url);
        my $http = self ?? $!http // %options<http> !! %options<http>;
        with $http {
            unless $_ eq '1.1' || $_ eq '2' || $_ eqv <1.1 2> {
                die X::Cro::HTTP::Client::InvalidVersion.new;
            }
        }
        else {
            $http = '';
        }
        my Cro::Uri $proxy-url = self!get-proxy-url($parsed-url);
        my Cro::Policy::Timeout $timeout-policy;
        my $request-object = self!assemble-request($method, $parsed-url, $proxy-url, %options, $timeout-policy);

        my constant $redirect-codes = set(301, 302, 303, 307, 308);
        my $enable-push = self ?? $!push-promises // %options<push-promises> !! %options<push-promises>;

        Promise(supply {
            my $request-start-time = now;
            my $conn-timeout = $timeout-policy.get-timeout(0, 'connection');
            my $goaway-retries = self ?? $!http2-goaway-retries !! %options<http2-goaway-retries> // 1;
            my Supplier $retry-supplier .= new;
            my $retry-supply = $retry-supplier.Supply;
            sub do-request-on-pipeline() {
                whenever self!get-pipeline($proxy-url // $parsed-url, $http, $conn-timeout, $request-log, ca => %options<ca>, tls => %options<tls> // %options<ssl>, :$enable-push) -> $pipeline {

                    # Handle connection persistence.
                    if $pipeline !~~ Pipeline2 {
                        unless self.persistent || $request-object.has-header('connection') {
                            $request-object.append-header('Connection', 'close');
                        }
                    }

                    # Set up any timeout for receiving the response headers.
                    my $timeout = $timeout-policy.get-timeout(now - $request-start-time, 'headers');
                    my Bool $headers-kept = False;
                    if $timeout !~~ Inf {
                        whenever Promise.in($timeout) {
                            die X::Cro::HTTP::Client::Timeout.new(phase => 'headers', uri => $url) unless $headers-kept || $pipeline.dead;
                        }
                    }

                    # Send the request.
                    whenever $pipeline.send-request($request-object) {
                        QUIT {
                            $request-log.end;
                            when GoAwayRetry {
                                if $goaway-retries > 0 && !$headers-kept {
                                    $retry-supplier.emit: True;
                                }
                                else {
                                    .goaway-exception.rethrow;
                                }
                            }
                            when PipelineClosedBeforeHeaders {
                                if $goaway-retries > 0 && !$headers-kept {
                                    $retry-supplier.emit: True;
                                }
                                else {
                                    .rethrow;
                                }
                            }
                        }
                        $headers-kept = True;

                        # Consider adding the connection back into the cache to use it
                        # again.
                        if self && $!persistent {
                            unless .http-version eq '1.0' || (.header('connection') // '').lc eq 'close' {
                                $!connection-cache.add-pipeline($pipeline);
                            }
                        }
                        else {
                            $pipeline.close;
                        }

                        # If there's a body timeout, enforce it. Note that we need to detach
                        # this from the current supply, since it outlives it.
                        my $body-timeout = $timeout-policy.get-timeout(now - $request-start-time, 'body');
                        if $body-timeout != Inf {
                            my $response-to-timeout = $_;
                            Promise.in($body-timeout).then: { $response-to-timeout.cancel }
                        }

                        # Set request object for received response.
                        .request = $request-object;
                        .request.http-version = $pipeline ~~ Pipeline2 ?? '2' !! '1.1';

                        # Pick next steps according to response.
                        if 200 <= .status < 400 || .status == 101 {
                            my $follow;
                            if self {
                                $follow = %options<follow> // $!follow // $DEFAULT-MAX-REDIRECTS;
                            } else {
                                $follow = %options<follow> // $DEFAULT-MAX-REDIRECTS;
                            }
                            if .status ⊂ $redirect-codes && ($follow !=== False) {
                                my $remain = $follow === True ?? 4 !! $follow.Int - 1;
                                if $remain < 0 {
                                    $request-log.end;
                                    die X::Cro::HTTP::Client::TooManyRedirects.new;
                                }
                                my $new-method = .status == 302 | 303 ?? 'GET' !! $method;
                                my %new-opts = %options;
                                %new-opts<follow> = $remain;
                                if .status == 302 | 303 {
                                    %new-opts<body>:delete;
                                    %new-opts<content-type>:delete;
                                    %new-opts<content-length>:delete;
                                }
                                my $new-url = $parsed-url.add(Cro::Uri::HTTP.parse-ref(.header('location')));
                                %new-opts<PARENT-REQUEST-LOG> = $request-log;
                                Cro::HTTP::LogTimeline::Redirected.log($request-log, :status(.status), :url($new-url));
                                my $req = self.request($new-method, $new-url, %new-opts);
                                CATCH { $request-log.end; }
                                whenever $req {
                                    QUIT { $request-log.end; }
                                    $request-log.end;
                                    .emit;
                                    done;
                                };
                            } else {
                                if self && $.cookie-jar.defined {
                                    $.cookie-jar.add-from-response($_, $parsed-url);
                                }
                                $request-log.end;
                                .emit;
                                done;
                            }
                        } elsif 400 <= .status < 500 {
                            my $auth;
                            if self {
                                $auth = %options<auth> // %!auth;
                            } else {
                                $auth = %options<auth> // {};
                            }
                            if .status == 401 && (%options<auth><if-asked>:exists) {
                                my %opts = %options;
                                %opts<auth><if-asked>:delete;
                                %opts<PARENT-REQUEST-LOG> = $request-log;
                                Cro::HTTP::LogTimeline::AuthorizationRequested.log($request-log);
                                CATCH { $request-log.end; }
                                whenever self.request($method, $parsed-url, %opts) {
                                    QUIT { $request-log.end; }
                                    $request-log.end;
                                    .emit;
                                    done;
                                };
                            } else {
                                Cro::HTTP::LogTimeline::ErrorResponse.log($request-log, :status(.status));
                                $request-log.end;
                                die X::Cro::HTTP::Error::Client.new(response => $_);
                            }
                        } elsif .status >= 500 {
                            Cro::HTTP::LogTimeline::ErrorResponse.log($request-log, :status(.status));
                            $request-log.end;
                            die X::Cro::HTTP::Error::Server.new(response => $_);
                        }
                    }
                }
            }

            whenever $retry-supply {
                $goaway-retries--;
                do-request-on-pipeline();
            }
            do-request-on-pipeline();
        })
    }

    #| Make a HTTP request, specifying the HTTP method (GET, POST, etc.),
    #| the URL, and any further request options. Returns a C<Promise> that
    #| will be kept with the response body if the request is successful.
    multi method request-body(Str $method, $url, *%options --> Promise) {
        self.request-body($method, $url, %options)
    }

    #| Make a HTTP request, specifying the HTTP method (GET, POST, etc.),
    #| the URL, and any further request options. Returns a C<Promise> that
    #| will be kept with the response body if the request is successful.
    multi method request-body(Str $method, $url, %options --> Promise) {
        # Take care to return the original Promise if it is broken, so we don't
        # add an extra layer of exception wrapping.
        my $response = self.request($method, $url, %options);
        await Promise.anyof($response);
        $response.status == Kept ?? $response.result.body !! $response
    }

    method !get-proxy-url($parsed-url) {
        if $parsed-url.scheme eq 'http' {
            if self { return $_ with $!http-proxy }
            return Nil if self!no-proxy($parsed-url);
            return Cro::Uri::HTTP.parse($_) with %*ENV<HTTP_PROXY>;
        }
        elsif $parsed-url.scheme eq 'https' {
            if self { return $_ with $!https-proxy }
            return Nil if self!no-proxy($parsed-url);
            return Cro::Uri::HTTP.parse($_) with %*ENV<HTTPS_PROXY>;
        }
        Nil
    }

    method !no-proxy($parsed-url) {
        if %*ENV<NO_PROXY> -> $no-proxy {
            my $check-host = $parsed-url.host;
            for $no-proxy.split(',') -> $matcher {
                return True if $matcher eq '*' || $check-host.ends-with($matcher);
            }
        }
        return False;
    }

    method !get-pipeline(Cro::Uri $url, $http, $conn-timeout, $log-parent, :$ca, :$tls, :$enable-push) {
        my $secure = $url.scheme.lc eq 'https';
        my $host = $url.host;
        my $port = $url.port // ($secure ?? 443 !! 80);
        if self && $!connection-cache.pipeline-for($secure, $host, $port, $http) -> $pipeline {
            Cro::HTTP::LogTimeline::ReuseConnection.log($log-parent,
                    :$host, :$port,
                    :secure($secure ?? 'Yes' !! 'No'),
                    :protocol(describe-protocol($http)));
            Promise.kept($pipeline)
        }
        else {
            self!build-pipeline($secure, $host, $port, $http, $conn-timeout, $log-parent, :$ca, :$tls, :$enable-push)
        }
    }

    sub describe-protocol($http) {
        $http eq '1.1' | '2' ?? $http !! 'Any'
    }

    my class VersionDecisionNotifier does Cro::Transform {
        has $.promise;
        has $.result;

        method consumes() { Cro::HTTP::Request }
        method produces() { Cro::HTTP::Request }
        method transformer($pipeline) {
            $!promise.keep($!result);
            return $pipeline;
        }
    }

    method !build-pipeline($secure, $host, $port, $http, $conn-timeout, $log-parent, :$ca = {}, :$tls = {}, :$enable-push) {
        my $log-connection = Cro::HTTP::LogTimeline::EstablishConnection.start(
                $log-parent, :$host, :$port,
                :secure($secure ?? 'Yes' !! 'No'),
                :protocol(describe-protocol($http)));
        my @parts;
        my $version-decision = Promise.new;
        my $supports-alpn = supports-alpn();
        if self {
            push @parts, RequestSerializerExtension.new:
                add-body-serializers => $.add-body-serializers,
                body-serializers => $.body-serializers;
        }
        if $http eq '2' {
            push @parts, Cro::HTTP2::RequestSerializer.new;
            push @parts, Cro::HTTP2::FrameSerializer.new(:client, :$enable-push);
            $version-decision.keep('2');
        }
        elsif $http eq '1.1' || !$secure || !$supports-alpn {
            push @parts, Cro::HTTP::RequestSerializer.new;
            $version-decision.keep('1.1');
        }
        else {
            push @parts, Cro::ConnectionConditional.new(
                { (.alpn-result // '') eq 'h2' } => [
                    VersionDecisionNotifier.new(:promise($version-decision), :result('2')),
                    Cro::HTTP2::RequestSerializer.new,
                    Cro::HTTP2::FrameSerializer.new(:client, :$enable-push)
                ],
                [
                    VersionDecisionNotifier.new(:promise($version-decision), :result('1.1')),
                    Cro::HTTP::RequestSerializer.new
                ]
            );
        }
        push @parts, self.choose-connector($secure);

        if $http eq '2' {
            push @parts, Cro::HTTP2::FrameParser.new(:client);
            push @parts, Cro::HTTP2::ResponseParser.new(:$enable-push);
        }
        elsif $http eq '1.1' || !$secure || !$supports-alpn {
            push @parts, Cro::HTTP::ResponseParser.new();
        }
        else {
            push @parts, Cro::ConnectionConditional.new(
                { (.alpn-result // '') eq 'h2' } => [
                    Cro::HTTP2::FrameParser.new(:client),
                    Cro::HTTP2::ResponseParser.new()
                ],
                Cro::HTTP::ResponseParser.new()
            );
        }
        if self {
            push @parts, ResponseParserExtension.new:
                add-body-parsers => $.add-body-parsers,
                body-parsers => $.body-parsers;
        }
        my $connector = Cro.compose(|@parts);

        my %tls-config;
        if $secure {
            %tls-config =
                    (%!tls if self),
                    %$tls,
                    (alpn => ($http eq 'h2' ?? 'h2' !! <h2 http/1.1>)
                        if $supports-alpn && $http ne '1.1'),
                    ((self ?? (self.ca // %$ca) !! %$ca) // Empty);
        }
        my $in = Supplier::Preserving.new;
        my $out = $version-decision
            ?? establish($connector, $in.Supply, $log-connection, :nodelay, :$host, :$port, :$conn-timeout, |%tls-config)
            !! do {
                my $s = Supplier::Preserving.new;
                establish($connector, $in.Supply, $log-connection, :nodelay, :$host, :$port, :$conn-timeout, |%tls-config).tap:
                    { $s.emit($_) },
                    done => { $s.done },
                    quit => {
                        try $version-decision.break($_);
                        $s.quit($_);
                    };
                $s.Supply
            };
        $version-decision.then: -> $version {
            $version.result eq '2'
                ?? Pipeline2.new(:$secure, :$host, :$port, :$in, :$out)
                !! Pipeline.new(:$secure, :$host, :$port, :$in, :$out)
        }
    }

    sub establish(Cro::Connector $connector, Supply $incoming, $log-connection, :$conn-timeout, *%options) {
        my $connection-obtained = False;
        supply {
            whenever Promise.in($conn-timeout) {
                die X::Cro::HTTP::Client::Timeout.new(phase => 'connection', uri => %options<host>) unless $connection-obtained;
            }

            my Promise $connection = $connector.connect(|%options);
            $connection.then({
                $connection-obtained = True;
                $log-connection.end;
            });
            whenever $connection -> Cro::Transform $transform {
                whenever $transform.transformer($incoming) -> $msg {
                    emit $msg;
                    LAST done;
                }
            }
        }
    }

    sub calculate-timeout($value, Cro::Policy::Timeout $timeout-policy is rw) {
        my $curr-timeout;
        given $value {
            when Map:D {
                my %phases;
                for $_.kv -> $k, $v {
                    %phases{$k} = Real($v);
                }
                $curr-timeout = Cro::HTTP::Client::Policy::Timeout.new(total => Inf, |%phases);
            }
            when Real:D {
                $curr-timeout = Cro::HTTP::Client::Policy::Timeout.new(total => Real($_));
            }
            when Cro::Policy::Timeout:D {
                $curr-timeout = $_;
            }
            default {
                die X::Cro::HTTP::Client::InvalidTimeoutFormat.new(bad => $_);
            }
        }
        with $curr-timeout {
            $timeout-policy = $_;
        }
    }

    method !assemble-request(Str $method, Cro::Uri $base-url, Cro::Uri $proxy-url, %options, Cro::Policy::Timeout $timeout-policy is rw, --> Cro::HTTP::Request) {
        # Add any query string parameters.
        my $url;
        with %options<query> -> $query {
            my Cro::Uri::HTTP $http-uri = $base-url ~~ Cro::Uri::HTTP
                ?? $base-url
                !! Cro::Uri::HTTP.parse($base-url.Str);
            $url = $http-uri.add-query($query.list);
        }
        else {
            $url = $base-url;
        }

        # Form target and request object.
        # If we have a proxy URL, include the host along with the path.
        my $target = ($proxy-url ?? ~$url !! $url.path) || '/';
        $target ~= "?{$url.query}" if $url.query;
        my $request-uri = $proxy-url // $url;
        my $request = Cro::HTTP::Request.new(:$method, :$target, :$request-uri);
        my $port = $url.port;
        $request.append-header('Host', $url.host ~
            ($port && $port != 80 | 443 ?? ":$port" !! ""));

        # Add defaults from the instance, if we have one.
        if self {
            self!set-headers($request, @.headers.List);
            $request.append-header('content-type', $.content-type) if $.content-type;
            $.cookie-jar.add-to-request($request, $url) if $.cookie-jar;
            if %!auth && !(%options<auth>:exists) {
                self!form-authentication($request, %!auth, %options<if-asked>:exists);
            }
        }

        # Process options.
        my Bool $body-set = False;
        for %options.kv -> $_, $value {
            when 'body' {
                if !$body-set {
                    $request.set-body($value);
                    $body-set = True;
                } else {
                    die X::Cro::HTTP::Client::BodyAlreadySet.new;
                }
            }
            when 'body-byte-stream' {
                if !$body-set {
                    $request.set-body-byte-stream($value);
                    $body-set = True;
                } else {
                    die X::Cro::HTTP::Client::BodyAlreadySet.new;
                }
            }
            when 'content-type' {
                $request.append-header('content-type', $value)
            }
            when 'headers' {
                self!set-headers($request, $value.List) if $value ~~ Iterable;
            }
            when 'auth' {
                self!form-authentication: $request, %$value, %$value<if-asked>:exists;
            }
            when 'cookies' {
                for $value.list {
                    when Cro::HTTP::Cookie {
                        $request.add-cookie($_);
                    }
                    when Pair {
                        $request.add-cookie(.key, .value);
                    }
                    default {
                        die X::Cro::HTTP::Client::InvalidCookie.new(bad => $_);
                    }
                }
            }
            when 'timeout' {
                calculate-timeout($value, $timeout-policy);
            }
        }

        my $default-timeout = Cro::HTTP::Client::Policy::Timeout.new(:total(Inf));
        ($timeout-policy = self ?? $!timeout-policy // $default-timeout !! $default-timeout) without $timeout-policy;

        # Set User-agent, check if wasn't set already for us
        unless $request.has-header('User-agent') {
            # These checks are required to skip header setting
            # if it is set to Nil or empty string by the user
            if %options<user-agent>:exists {
                with %options<user-agent> {
                    $request.append-header('User-agent', $_) if $_;
                }
            } elsif self && $!user-agent {
                $request.append-header('User-agent', $!user-agent);
            } else {
                $request.append-header('User-agent', 'Cro');
            }
        }

        return $request;
    }

    method !form-authentication($request, %data, Bool $skip) {
        return if $skip;
        if %data<username>:exists {
            my $hash = encode-base64("{%data<username>}:{%data<password>}", :str);
            $request.append-header('Authorization', "Basic $hash");
        } else {
            $request.append-header('Authorization', "Bearer {%data<bearer>}");
        }
    }

    method !set-headers($request, @headers) {
        for @headers {
            when Pair | Cro::HTTP::Header {
                $request.append-header($_)
            }
            default {
                die X::Cro::HTTP::Client::IncorrectHeaderType.new(what => $_);
            }
        }
    }

    #| Returns the underlying connector used by the HTTP client in order to make
    #| a TCP or TLS condition. Can be overridden to customize the transport used;
    #| for example, Cro::HTTP::Test uses this to fake a connection.
    method choose-connector($secure) {
        $secure ?? Cro::TLS::Connector !! Cro::TCP::Connector
    }
}
