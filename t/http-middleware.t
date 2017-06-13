use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Cro::HTTP::Client;
use Cro::Service;
use Cro::Transform;
use Test;

constant TEST_PORT = 31314;

# Application
my $application = route {
    get -> {
        content 'text/html', "<strong>Hello from Cro!</strong>";
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
    dies-ok { await IO::Socket::Async.connect('localhost', TEST_PORT) },
        'Server not listening until started';
    lives-ok { $service.start }, 'Can start service';

    my $url = "http://localhost:{TEST_PORT}";

    given await Cro::HTTP::Client.get("$url") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Response with after middleware is okay';
        is $resp.header('Strict-Transport-Security'), "max-age=60", 'Header was set';
    }

    LEAVE $service.stop();
}

{
    my Cro::Service $service = Cro::HTTP::Server.new(
        :host('localhost'), :port(TEST_PORT), application => $application,
        before => LowerCase
    );
    dies-ok { await IO::Socket::Async.connect('localhost', TEST_PORT) },
        'Server not listening until started';
    lives-ok { $service.start }, 'Can start service';

    my $url = "http://localhost:{TEST_PORT}";

    given await Cro::HTTP::Client.get("$url/index.SHTML") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Response with before middleware is okay';
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
    dies-ok { await IO::Socket::Async.connect('localhost', TEST_PORT) },
        'Server not listening until started';
    lives-ok { $service.start }, 'Can start service';

    my $url = "http://localhost:{TEST_PORT}";

    given await Cro::HTTP::Client.get("$url/index.SHTML") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'before and after can work together';
        is $resp.header('Strict-Transport-Security'), "max-age=60", 'after works with before';
        is await($resp.body-text), 'Correct Answer', 'before works with after';
    }

    LEAVE $service.stop();
}

done-testing;
