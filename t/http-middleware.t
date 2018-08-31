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
            before-matched LowerCase;
            after-matched StrictTransportSecurity.new(max-age => Duration.new(60));
            delegate <*> => $application;
        }

        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $mw-app
        );
        $service.start;
        LEAVE $service.stop();

        given await Cro::HTTP::Client.get("$url/index.SHTML") -> $resp {
            is await($resp.body-text), 'Correct Answer',
                'Request middleware works with before-matched in route block';
            is $resp.header('Strict-Transport-Security'), "max-age=60",
                'Response middleware works with after-matched in route block';
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

    {
        my $mw-app = route {
            before-matched ForbiddenWithoutAuthHeader;
            delegate <*> => $application;
        }

        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $mw-app
        );
        $service.start;
        LEAVE $service.stop();

        throws-like { await Cro::HTTP::Client.get("$url") },
            X::Cro::HTTP::Error::Client,
            response => { .status == 403 },
            'Got 403 response from middleware when no auth header (before-matched in router)';

        my %headers = Authorization => 'Bearer Polarer';
        given await Cro::HTTP::Client.get("$url", :%headers) -> $resp {
            is $resp.status, 200, 'Got 200 normal response with an auth header (before-matched in router)';
        }
    }

    {
        my $mw-app = route {
            before-matched ForbiddenWithoutAuthHeader;
            include $application;
        }

        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $mw-app
        );
        $service.start;
        LEAVE $service.stop();

        throws-like { await Cro::HTTP::Client.get("$url") },
            X::Cro::HTTP::Error::Client,
            response => { .status == 403 },
            'Got 403 response from middleware when no auth header (before-matched + include in router)';

        my %headers = Authorization => 'Bearer Polarer';
        given await Cro::HTTP::Client.get("$url", :%headers) -> $resp {
            is $resp.status, 200,
                'Got 200 normal response with an auth header (before-matched + include in router)';
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

    {
        my $mw-app = route {
            before-matched OverlySimpleCache.new;
            delegate <*> => $application;
        }

        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $mw-app
        );
        $service.start;
        LEAVE $service.stop();

        given await Cro::HTTP::Client.get("$url/counter") -> $resp {
            is $resp.status, 200, 'Got 200 response on first request (before-matched in router)';
            ok $resp.has-header('X-Uncached'), 'Response part added header (before-matched in router)';
            is await($resp.body-text), '2', 'Expected body (before-matched in router)';
        }

        given await Cro::HTTP::Client.get("$url/counter") -> $resp {
            is $resp.status, 200, 'Got 200 response on second request (before-matched in router)';
            nok $resp.has-header('X-Uncached'),
                'Response part did not run on early response (before-matched in router)';
            is await($resp.body-text), '2', 'Got cached body (before-matched in router)';
        }
    }

    {
        my $mw-app = route {
            before-matched OverlySimpleCache.new;
            include $application;
        }

        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $mw-app
        );
        $service.start;
        LEAVE $service.stop();

        given await Cro::HTTP::Client.get("$url/counter") -> $resp {
            is $resp.status, 200,
                'Got 200 response on first request (before-matched + include in router)';
            ok $resp.has-header('X-Uncached'),
                'Response part added header (before-matched + include in router)';
            is await($resp.body-text), '3', 'Expected body (before-matched + include in router)';
        }

        given await Cro::HTTP::Client.get("$url/counter") -> $resp {
            is $resp.status, 200,
                'Got 200 response on second request (before-matched + include in router)';
            nok $resp.has-header('X-Uncached'),
                'Response part did not run on early response (before-matched + include in router)';
            is await($resp.body-text), '3',
                'Got cached body (before-matched + include in router)';
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
        before-matched PreHeaderMiddleware.new(:value<Rock>);
        after-matched  PostHeaderMiddleware.new(:value<Roll>);

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
        before-matched PreHeaderMiddleware.new(:value<foo>);
        after-matched  PostHeaderMiddleware.new(:value<bar>);
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
            is $resp.header('Post-Custom'), 'bar', 'per-route after-matched middleware for regular request works';
            is await($resp.body-text), 'Correct Answer', 'per-route before-matched middleware for regular request works';
        }

        given await Cro::HTTP::Client.get("$url/d") -> $resp {
            is $resp.header('Post-Custom'), 'bar', 'per-route after-matched middleware for delegated request works';
            is await($resp.body-text), 'Correct Answer', 'per-route before-matched middleware for delegated request works';
        }

        given await Cro::HTTP::Client.get("$url/home") -> $resp {
            is $resp.header('Post-Custom'), 'bar', 'per-route after-matched middleware for includee works';
            is await($resp.body-text), 'Correct Answer', 'per-route before-matched middleware for includee works';
        }

        given await Cro::HTTP::Client.get("$url/home-redef") -> $resp {
            is $resp.header('Post-Custom'), 'Roll,bar', 'per-route after-matched middleware for includee works';
            is await($resp.body-text), 'Correct Answer', 'per-route before-matched middleware for includee works';
        }

        LEAVE $service.stop();
    }

    my $block-app = route {
        after-matched {
            header 'Strict-transport-security', 'max-age=31536000; includeSubDomains';
        }
        before-matched {
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
            is await($resp.body-text), 'Correct Answer', 'per-route block before-matched middleware works';
            is $resp.header('Strict-transport-security'), 'max-age=31536000; includeSubDomains',
                'per-route block after-matched middleware works';
        }
        LEAVE $service.stop();
    }

    dies-ok {
        my $block-app = route {
            after-matched PreHeaderMiddleware.new(:value<foo>);
            get -> {
                content 'text/html', 'Dies';
            }
        }
    }, 'Cannot use wrong typed Transformer as a middleware';
}, 'Interaction of middleware written as Cro::Transform with HTTP router';

subtest {
    my $mw-app = route {
        before-matched {
            forbidden unless .has-header('Authorization');
        }

        get -> {
            content 'text/html', "<strong>Hello from Cro!</strong>";
        }
    }

    my Cro::Service $service = Cro::HTTP::Server.new(
        :host('localhost'), :port(TEST_PORT), application => $mw-app
    );
    $service.start;
    LEAVE $service.stop();

    throws-like { await Cro::HTTP::Client.get("$url") },
        X::Cro::HTTP::Error::Client,
        response => { .status == 403 },
        'Block form of before-matched in router can produce an early response';

    my %headers = Authorization => 'Bearer Polarer';
    given await Cro::HTTP::Client.get("$url", :%headers) -> $resp {
        is $resp.status, 200,
            'Block form of before-matched not producing a response also works';
    }
}, 'Conditional response in block form of before-matched in router';

{
    my class LowerCase does Cro::HTTP::Middleware::Request {
        method process(Supply $requests --> Supply) {
            supply whenever $requests -> $request {
                $request.target = $request.target.lc;
                emit $request;
            }
        }
    }
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
    my $mw-app = route {
        delegate <*> => $application;
        after-matched StrictTransportSecurity.new(max-age => Duration.new(60));
        before-matched LowerCase;
    }

    my Cro::Service $service = Cro::HTTP::Server.new(
        :host('localhost'), :port(TEST_PORT), application => $mw-app
    );
    $service.start;
    LEAVE $service.stop();

    given await Cro::HTTP::Client.get("$url/index.SHTML") -> $resp {
        is await($resp.body-text), 'Correct Answer',
            'before-matched applies even to delegate done before it';
        is $resp.header('Strict-Transport-Security'), "max-age=60",
            'after-matched applies even to delegate done after it';
    }
}

{
    my $block-app = route {
        get -> {
            if request.header('Custom-header') eq 'Foo' {
                content 'text/html', 'Correct Answer';
            } else {
                content 'text/html', 'Incorrect answer';
            }
        }
        after-matched {
            header 'Strict-transport-security', 'max-age=31536000; includeSubDomains';
        }
        before-matched {
            .append-header('Custom-header', 'Foo');
        }
    }

    {
        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $block-app
        );
        $service.start;

        given await Cro::HTTP::Client.get("$url/") -> $resp {
            is await($resp.body-text), 'Correct Answer', 'before-matched applies even to a route before it';
            is $resp.header('Strict-transport-security'), 'max-age=31536000; includeSubDomains',
                'after-matched middleware applies even to a route before it';
        }
        LEAVE $service.stop();
    }
}

{
    my $before-p = Promise.new;
    my $before-m-p = Promise.new;
    my $after-p = Promise.new;
    my $after-m-p = Promise.new;

    my $app = route {
        before-matched { $before-m-p.keep }
        before { $before-p.keep }
        after { $after-p.keep }
        after-matched { $after-m-p.keep }
    }

    my Cro::Service $service = Cro::HTTP::Server.new(
        :host('localhost'), :port(TEST_PORT), application => $app
    );
    $service.start;
    LEAVE $service.stop();

    dies-ok { await Cro::HTTP::Client.get("$url") }, 'Dies when no matched rule';
    ok $before-p.status ~~ Kept, 'before block was executed';
    ok $before-m-p.status !~~ Kept, 'before-matched block was not executed';
    ok $after-p.status ~~ Kept, 'after block was executed';
    ok $after-m-p.status !~~ Kept, 'after-matched block was not executed';
}

{
    {
        my $app = route {
            before { $_.target = $_.target.lc }
            after { $_.append-header('Strict-Transport-Security', "max-age=60") }
            get -> 'home' { content 'text/html', "Home" }
        }
        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $app
        );
        $service.start;
        LEAVE $service.stop();

        given await Cro::HTTP::Client.get("$url/HOME") -> $resp {
            is $resp.header('Strict-transport-security'), 'max-age=60', "before and after is run from block definition";
        }
    }

    {
        my class LowerCase does Cro::HTTP::Middleware::Request {
            method process(Supply $requests --> Supply) {
                supply whenever $requests -> $request {
                    $request.target = $request.target.lc;
                    emit $request;
                }
            }
        }
        my class StrictTransportSecurity does Cro::HTTP::Middleware::Response {
            has Duration:D $.max-age is required;

            method process(Supply $responses --> Supply) {
                supply whenever $responses -> $response {
                    $response.append-header('Strict-Transport-Security', "max-age=$!max-age");
                    emit $response;
                }
            }
        }

        my $app = route {
            before LowerCase.new;
            after StrictTransportSecurity.new(max-age => Duration.new(12341234));
            get -> 'home' { content 'text/html', "Home" }
        }

        my Cro::Service $service = Cro::HTTP::Server.new(
            :host('localhost'), :port(TEST_PORT), application => $app
        );
        $service.start;
        LEAVE $service.stop();

        given await Cro::HTTP::Client.get("$url/HOME") -> $resp {
            is $resp.header('Strict-transport-security'), 'max-age=12341234', "before and after is run from class definition";
        }
    }

    {
        my class Middle does Cro::HTTP::Middleware::RequestResponse {
            method process-requests(Supply $requests) {
                supply whenever $requests -> $r {
                    $r.target = $r.target.lc;
                    emit $r;
                }
            }
            method process-responses(Supply $responses) {
                supply whenever $responses -> $r {
                    $r.append-header('Strict-Transport-Security', "max-age=6420");
                    emit $r;
                }
            }
        }

        my $app = route {
            before Middle.new;
            get -> 'home' { content 'text/html', "Home" }
        }

        my Cro::Service $service = Cro::HTTP::Server.new(:host('localhost'), :port(TEST_PORT), application => $app);
        $service.start;
        LEAVE $service.stop();

        given await Cro::HTTP::Client.get("$url/HOME") -> $resp {
            is $resp.header('Strict-transport-security'), 'max-age=6420', "before and after is run from RequestResponse(Pair) definition";
        }
    }
}

{
    my class MySession does Cro::HTTP::Auth {
        has $.is-logged-in;
        has $.is-admin;
    }

    subset LoggedIn of MySession where *.is-logged-in;
    subset Admin of MySession where *.is-admin;

    my class Fake::Auth::Middleware does Cro::HTTP::Middleware::Request {
        has $.second is rw = False;

        method process(Supply $requests --> Supply) {
            supply whenever $requests -> $request {
                $request.auth = $!second ?? MySession.new(:is-admin) !! MySession.new(:is-logged-in);
                $!second = True;
                emit $request;
            }
        }
    }

    my $middle = Fake::Auth::Middleware.new;
    my $app = route {
        before $middle;
        after { redirect '/401' if .status == 401 }
        get -> LoggedIn $user, 'foo' {
            content 'text/plain', 'user';
        }
        get -> Admin $user, 'foo' {
            content 'text/plain', 'admin';
        }
        get -> Admin $user, 'private' {
            content 'text/plain', 'Top secret info';
        }
        get -> '401' {
            content 'text/plain', 'Too bad';
        }
    }

    my Cro::Service $service = Cro::HTTP::Server.new(:host('localhost'), :port(TEST_PORT), application => $app);
    $service.start;
    LEAVE $service.stop();

    given await Cro::HTTP::Client.get("$url/foo") -> $resp {
        is (await $resp.body-text), 'user', 'Auth middleware is applied';
    }
    given await Cro::HTTP::Client.get("$url/foo") -> $resp {
        is (await $resp.body-text), 'admin', 'Auth middleware is applied 2';
    }

    $middle.second = False;

    given await Cro::HTTP::Client.get("$url/private") -> $resp {
        is (await $resp.body-text), 'Too bad', 'After middleware is applied';
    }
}

done-testing;
