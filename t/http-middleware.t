use Cro::TCP;
use Cro::HTTP::Client;
use Cro::HTTP::Middleware;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Cro::Service;
use Cro::Transform;
use Test;

constant TEST_PORT = 31315;
my $url = "http://localhost:{TEST_PORT}";

# Application
my $application = route {
    get -> {
        content 'text/html', "<strong>Hello from Cro!</strong>";
    }

    get -> 'echo' {
        request-body -> $body {
            content 'text/plain', "$body";
        }
    }

    get -> 'index.shtml' {
        content 'text/html', "Correct Answer";
    }

    get -> 'index.SHTML' {
        content 'text/html', "Incorrect Answer";
    }

    my atomicint $i = 0;
    get -> 'counter' {
        content 'text/plain', (++⚛$i).Str;
    }
};

subtest {
    # Request middleware written as a transform
    my class LowerCase does Cro::Transform {
        method consumes() { Cro::HTTP::Request }
        method produces() { Cro::HTTP::Request }

        method transformer(Supply $pipeline --> Supply) {
            supply {
                whenever $pipeline -> $request {
                    $request.target = $request.target.lc;
                    emit $request;
                }
            }
        }
    }

    # Response middleware written as a transform
    my class StrictTransportSecurity does Cro::Transform {
        has Duration:D $.max-age is required;

        method consumes() { Cro::HTTP::Response }
        method produces() { Cro::HTTP::Response }

        method transformer(Supply $pipeline --> Supply) {
            supply {
                whenever $pipeline -> $response {
                    $response.append-header:
                    'Strict-Transport-Security',
                    "max-age=$!max-age";
                    emit $response;
                }
            }
        }
    }

    {
        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $application,
            after => StrictTransportSecurity.new(max-age => Duration.new(60))
        );
        $service.start;

        given await Cro::HTTP::Client.get("$url") -> $resp {
            is $resp.header('Strict-Transport-Security'), "max-age=60", 'Header was set';
        }

        LEAVE $service.stop();
    }

    {
        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $application,
            before => LowerCase
        );
        $service.start;

        given await Cro::HTTP::Client.get("$url/index.SHTML") -> $resp {
            is await($resp.body-text), 'Correct Answer', 'Target was processed';
        }

        LEAVE $service.stop();
    }

    {
        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $application,
            before => LowerCase,
            after => StrictTransportSecurity.new(max-age => Duration.new(60))
        );
        $service.start;

        given await Cro::HTTP::Client.get("$url/index.SHTML") -> $resp {
            is $resp.header('Strict-Transport-Security'), "max-age=60", 'after works with before';
            is await($resp.body-text), 'Correct Answer', 'before works with after';
        }

        LEAVE $service.stop();
    }
}, 'Request and response middleware written using a transform';

subtest {
    # Request middleware written using Cro::HTTP::Middleware::Request
    my class LowerCase does Cro::HTTP::Middleware::Request {
        method process(Supply $requests --> Supply) {
            supply whenever $requests -> $request {
                $request.target = $request.target.lc;
                emit $request;
            }
        }
    }

    # Response middleware written using Cro::HTTP::Middleware::Response
    my class StrictTransportSecurity does Cro::HTTP::Middleware::Response {
        has Duration:D $.max-age is required;

        method process(Supply $responses --> Supply) {
            supply whenever $responses -> $response {
                $response.append-header:
                    'Strict-Transport-Security',
                    "max-age=$!max-age";
                emit $response;
            }
        }
    }

    {
        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $application,
            after => StrictTransportSecurity.new(max-age => Duration.new(60))
        );
        $service.start;

        given await Cro::HTTP::Client.get("$url") -> $resp {
            is $resp.header('Strict-Transport-Security'), "max-age=60", 'Header was set';
        }

        LEAVE $service.stop();
    }

    {
        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $application,
            before => LowerCase
        );
        $service.start;

        given await Cro::HTTP::Client.get("$url/index.SHTML") -> $resp {
            is await($resp.body-text), 'Correct Answer', 'Target was processed';
        }

        LEAVE $service.stop();
    }

    {
        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $application,
            before => LowerCase,
            after => StrictTransportSecurity.new(max-age => Duration.new(60))
        );
        $service.start;

        given await Cro::HTTP::Client.get("$url/index.SHTML") -> $resp {
            is $resp.header('Strict-Transport-Security'), "max-age=60", 'after works with before';
            is await($resp.body-text), 'Correct Answer', 'before works with after';
        }

        LEAVE $service.stop();
    }

    {
        my $mw-app = route {
            before LowerCase;
            after StrictTransportSecurity.new(max-age => Duration.new(60));
            delegate <*> => $application;
        }

        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $mw-app
        );
        $service.start;
        LEAVE $service.stop();

        given await Cro::HTTP::Client.get("$url/index.SHTML") -> $resp {
            is await($resp.body-text), 'Correct Answer',
                'Request middleware works with before in route block';
            is $resp.header('Strict-Transport-Security'), "max-age=60",
                'Response middleware works with after in route block';
        }
    }
}, 'Request and response middleware written using a Cro::HTTP::Middleware roles';

subtest {
    my class ForbiddenWithoutAuthHeader does Cro::HTTP::Middleware::Conditional {
        method process(Supply $requests) {
            supply whenever $requests -> $request {
                emit $request.has-header('Authorization')
                    ?? $request
                    !! Cro::HTTP::Response.new(:$request, :403status);
            }
        }
    }

    {
        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $application,
            before => ForbiddenWithoutAuthHeader
        );
        $service.start;
        LEAVE $service.stop();

        throws-like { await Cro::HTTP::Client.get("$url") },
            X::Cro::HTTP::Error::Client,
            response => { .status == 403 },
            'Got 403 response from middleware when no auth header';

        my %headers = Authorization => 'Bearer Polarer';
        given await Cro::HTTP::Client.get("$url", :%headers) -> $resp {
            is $resp.status, 200, 'Got 200 normal response with an auth header';
        }
    }
}, 'Conditional response middleware using Cro::HTTP::Middleware::Conditional';

subtest {
    my class OverlySimpleCache does Cro::HTTP::Middleware::RequestResponse {
        has $!cached-blob;

        method process-requests(Supply $requests) {
            supply whenever $requests -> $request {
                if $!cached-blob {
                    given Cro::HTTP::Response.new(:$request, :200status) {
                        .set-body-byte-stream: supply emit $!cached-blob;
                        .emit;
                    }
                }
                else {
                    emit $request;
                }
            }
        }

        method process-responses(Supply $responses) {
            supply whenever $responses -> $response {
                whenever $response.body-blob -> $!cached-blob {
                    $response.set-body-byte-stream: supply emit $!cached-blob;
                    $response.append-header: 'X-Uncached', 'true';
                    emit $response;
                }
            }
        }
    }

    {
        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $application,
            before => OverlySimpleCache.new
        );
        $service.start;
        LEAVE $service.stop();

        given await Cro::HTTP::Client.get("$url/counter") -> $resp {
            is $resp.status, 200, 'Got 200 response on first request';
            ok $resp.has-header('X-Uncached'), 'Response part added header';
            is await($resp.body-text), '1', 'Expected body';
        }

        given await Cro::HTTP::Client.get("$url/counter") -> $resp {
            is $resp.status, 200, 'Got 200 response on second request';
            nok $resp.has-header('X-Uncached'), 'Response part did not run on early response';
            is await($resp.body-text), '1', 'Got cached body';
        }
    }
}, 'Request/response middleware using Cro::HTTP::Middleware::RequestResponse';

subtest {
    my class UpperCase does Cro::Transform {
        method consumes() { Cro::TCP::Message }
        method produces() { Cro::TCP::Message }

        method transformer(Supply $pipeline --> Supply) {
            supply {
                whenever $pipeline -> $message {
                    emit Cro::TCP::Message.new(data =>
                        $message.data.decode.subst('hello', 'HELLO').encode('latin-1'));
                }
            }
        }
    }

    {
        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $application,
            before-parse => UpperCase);
        $service.start;

        given await Cro::HTTP::Client.get("$url/echo",
                                          content-type => 'text/plain',
                                          body => "hello WORLD") -> $resp {
            is await($resp.body-text), 'HELLO WORLD', 'before-parse works';
        }

        LEAVE $service.stop();
    }

    {
        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $application,
            after-serialize => UpperCase);
        $service.start;

        given await Cro::HTTP::Client.get("$url/echo",
                                          content-type => 'text/plain',
                                          body => "hello WORLD") -> $resp {
            is await($resp.body-text), 'HELLO WORLD', 'after-serialize works';
        }

        LEAVE $service.stop();
    }
}, 'Byte-level middleware, before/after request is parsed';

subtest {
    my class PreHeaderMiddleware does Cro::Transform {
        has $.value;

        method consumes() { Cro::HTTP::Request }
        method produces() { Cro::HTTP::Request }

        method transformer(Supply $pipeline --> Supply) {
            supply {
                whenever $pipeline {
                    .append-header('Custom-header', $!value);
                    .emit;
                }
            }
        }
    }

    my class PostHeaderMiddleware does Cro::Transform {
        has $.value;

        method consumes() { Cro::HTTP::Response }
        method produces() { Cro::HTTP::Response }

        method transformer(Supply $pipeline --> Supply) {
            supply {
                whenever $pipeline {
                    .append-header('Post-Custom', $!value);
                    .emit;
                }
            }
        }
    }

    my class TestDelegate does Cro::Transform {
        method consumes() { Cro::HTTP::Request }
        method produces() { Cro::HTTP::Response }

        method transformer(Supply $in --> Supply) {
            supply whenever $in -> $request {
                my $resp = Cro::HTTP::Response.new(:$request, :200status);
                if $request.has-header('Custom-header') {
                    $resp.set-body("Correct Answer");
                } else {
                    $resp.set-body("Incorrect Answer")
                }
                emit $resp;
            }
        }
    }

    my $inner-redef = route {
        before PreHeaderMiddleware.new(:value<Rock>);
        after  PostHeaderMiddleware.new(:value<Roll>);

        get -> 'home-redef' {
            if request.header('Custom-header') eq 'foo,Rock' {
                content 'text/html', "Correct Answer";
            } else {
                content 'text/html', "Incorrect Answer";
            }
        }
    }

    my $inner = route {
        get -> 'home' {
            if request.header('Custom-header') eq 'foo' {
                content 'text/html', "Correct Answer";
            } else {
                content 'text/html', "Incorrect Answer";
            }
        }
    }

    # Application with built-in middleware
    my $app = route {
        before PreHeaderMiddleware.new(:value<foo>);
        after  PostHeaderMiddleware.new(:value<bar>);
        get -> {
            if request.header('Custom-header') eq 'foo' {
                content 'text/html', "Correct Answer";
            } else {
                content 'text/html', "Incorrect Answer";
            }
        }
        delegate d => TestDelegate.new;
        include $inner;
        include $inner-redef;
    };

    {
        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $app
        );
        $service.start;

        given await Cro::HTTP::Client.get("$url/") -> $resp {
            is $resp.header('Post-Custom'), 'bar', 'per-route after middleware for regular request works';
            is await($resp.body-text), 'Correct Answer', 'per-route before middleware for regular request works';
        }

        given await Cro::HTTP::Client.get("$url/d") -> $resp {
            is $resp.header('Post-Custom'), 'bar', 'per-route after middleware for delegated request works';
            is await($resp.body-text), 'Correct Answer', 'per-route before middleware for delegated request works';
        }

        given await Cro::HTTP::Client.get("$url/home") -> $resp {
            is $resp.header('Post-Custom'), 'bar', 'per-route after middleware for includee works';
            is await($resp.body-text), 'Correct Answer', 'per-route before middleware for includee works';
        }

        given await Cro::HTTP::Client.get("$url/home-redef") -> $resp {
            is $resp.header('Post-Custom'), 'Roll,bar', 'per-route after middleware for includee works';
            is await($resp.body-text), 'Correct Answer', 'per-route before middleware for includee works';
        }

        LEAVE $service.stop();
    }

    my $block-app = route {
        after {
            header 'Strict-transport-security', 'max-age=31536000; includeSubDomains';
        }
        before {
            .append-header('Custom-header', 'Foo');
        }
        get -> {
            if request.header('Custom-header') eq 'Foo' {
                content 'text/html', 'Correct Answer';
            } else {
                content 'text/html', 'Incorrect answer';
            }
        }
    }

    {
        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $block-app
        );
        $service.start;

        given await Cro::HTTP::Client.get("$url/") -> $resp {
            is await($resp.body-text), 'Correct Answer', 'per-route block before middleware works';
            is $resp.header('Strict-transport-security'), 'max-age=31536000; includeSubDomains', 'per-route block after middleware works';
        }
        LEAVE $service.stop();
    }

    dies-ok {
        my $block-app = route {
            after PreHeaderMiddleware.new(:value<foo>);
            get -> {
                content 'text/html', 'Dies';
            }
        }
    }, 'Cannot use wrong typed Transformer as a middleware';
}, 'Interaction of middleware written as Cro::Transform with HTTP router';

done-testing;
