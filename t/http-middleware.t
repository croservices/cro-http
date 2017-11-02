use Cro::TCP;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Cro::HTTP::Client;
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
};

# Middleware
class StrictTransportSecurity does Cro::Transform {
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

# Middleware
class LowerCase does Cro::Transform {
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

class UpperCase does Cro::Transform {
    method consumes() { Cro::TCP::Message }
    method produces() { Cro::TCP::Message }

    method transformer(Supply $pipeline --> Supply) {
        supply {
            whenever $pipeline -> $message {
                emit Cro::TCP::Message.new(data => $message.data.decode.subst('hello', 'HELLO').encode('latin-1'));
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

class PreHeaderMiddleware does Cro::Transform {
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

class PostHeaderMiddleware does Cro::Transform {
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

class TestDelegate does Cro::Transform {
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

done-testing;
