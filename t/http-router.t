use Crow;
use Crow::HTTP::Request;
use Crow::HTTP::Router;
use Test;

sub body-text(Crow::HTTP::Response $r) {
    $r.get-body-stream.list.map(*.decode('utf-8')).join
}

{
    my $app = route -> { }
    ok $app ~~ Crow::Transform, 'Route block with no routes gives back a Crow::Transform';
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;
    $source.emit(Crow::HTTP::Request.new(:method<GET>, :target</>));
    given $responses.receive -> $r {
        ok $r ~~ Crow::HTTP::Response, 'Empty route set gives a response';
        is $r.status, '404', 'Status code from empty route set is 404';
    }
}

throws-like { request }, X::Crow::HTTP::Router::OnlyInHandler, what => 'request',
    'Can only use request term inside of a handler';
throws-like { response }, X::Crow::HTTP::Router::OnlyInHandler, what => 'response',
    'Can only use response term inside of a handler';

{
    my $app = route {
        get -> {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body('Hello, world'.encode('ascii'));
        }

        get -> 'about' {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body('We are the awesome'.encode('ascii'));
        }

        get -> 'company', 'careers' {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body('No jobs, kthxbai'.encode('ascii'));
        }
    }
    ok $app ~~ Crow::Transform, 'Route block with routes gives back a Crow::Transform';
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    $source.emit(Crow::HTTP::Request.new(:method<GET>, :target</>));
    given $responses.receive -> $r {
        ok $r ~~ Crow::HTTP::Response, 'Route set routes / correctly';
        is $r.status, 200, 'Got 200 response';
        is $r.header('Content-type'), 'text/html', 'Got expected header';
        is-deeply body-text($r), 'Hello, world', 'Got expected body';
    }

    $source.emit(Crow::HTTP::Request.new(:method<GET>, :target</about>));
    given $responses.receive -> $r {
        ok $r ~~ Crow::HTTP::Response, 'Route set routes /about correctly';
        is $r.status, 200, 'Got 200 response';
        is $r.header('Content-type'), 'text/html', 'Got expected header';
        is-deeply body-text($r), 'We are the awesome', 'Got expected body';
    }

    $source.emit(Crow::HTTP::Request.new(:method<GET>, :target</company/careers>));
    given $responses.receive -> $r {
        ok $r ~~ Crow::HTTP::Response, 'Route set routes /company/careers correctly';
        is $r.status, 200, 'Got 200 response';
        is $r.header('Content-type'), 'text/html', 'Got expected header';
        is-deeply body-text($r), 'No jobs, kthxbai', 'Got expected body';
    }

    $source.emit(Crow::HTTP::Request.new(:method<GET>, :target</wat>));
    given $responses.receive -> $r {
        ok $r ~~ Crow::HTTP::Response, 'No matching route gets a HTTP response';
        is $r.status, '404', 'Status code when no matching route is 404';
    }
}

{
    my $app = route {
        get -> 'product' {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body('A GET request'.encode('ascii'));
        }

        post -> 'product' {
            response.status = 201;
            response.append-header('Content-type', 'text/html');
            response.set-body('A POST request'.encode('ascii'));
        }

        put -> 'product' {
            response.status = 204;
        }

        delete -> 'product' {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body('A DELETE request'.encode('ascii'));
        }
    }
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    $source.emit(Crow::HTTP::Request.new(:method<GET>, :target</product>));
    given $responses.receive -> $r {
        ok $r ~~ Crow::HTTP::Response, 'Route set routes GET';
        is $r.status, 200, 'Got 200 response';
        is $r.header('Content-type'), 'text/html', 'Got expected header';
        is-deeply body-text($r), 'A GET request', 'Got expected body';
    }

    $source.emit(Crow::HTTP::Request.new(:method<POST>, :target</product>));
    given $responses.receive -> $r {
        ok $r ~~ Crow::HTTP::Response, 'Route set routes POST';
        is $r.status, 201, 'Got 201 response';
        is $r.header('Content-type'), 'text/html', 'Got expected header';
        is-deeply body-text($r), 'A POST request', 'Got expected body';
    }

    $source.emit(Crow::HTTP::Request.new(:method<PUT>, :target</product>));
    given $responses.receive -> $r {
        ok $r ~~ Crow::HTTP::Response, 'Route set routes PUT';
        is $r.status, 204, 'Got 204 response';
    }

    $source.emit(Crow::HTTP::Request.new(:method<DELETE>, :target</product>));
    given $responses.receive -> $r {
        ok $r ~~ Crow::HTTP::Response, 'Route set routes DELETE';
        is $r.status, 200, 'Got 200 response';
        is $r.header('Content-type'), 'text/html', 'Got expected header';
        is-deeply body-text($r), 'A DELETE request', 'Got expected body';
    }
}

{
    my $app = route {
        get -> 'product', $uuid {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("product $uuid".encode('ascii'));
        }

        get -> 'category', Any $uuid {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("category $uuid".encode('ascii'));
        }

        get -> 'user', Str $uuid {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("user $uuid".encode('ascii'));
        }

        get -> 'user', 'posts' {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("user posts".encode('ascii'));
        }

        get -> 'product', Str $uuid, 'reviews' {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("reviews $uuid".encode('ascii'));
        }

        get -> 'product', Str $uuid, 'reviews', Int $page {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("reviews $uuid page $page".encode('ascii'));
        }

        get -> 'tree', *@path {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body(@path.join(",").encode('ascii'));
        }

        get -> 'orders', 'history', Int $page? {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("order history ({$page // 'no page'})".encode('ascii'));
        }

        get -> 'category', 'tree', $leval-a = 'none-a', $level-b = 'none-b' {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("category tree $leval-a $level-b".encode('ascii'));
        }
    }
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    my @cases =
        '/product/123.456', 'product 123.456',
            'Mu variable at end handled correctly',
        '/category/124.556', 'category 124.556',
            'Any variable at end handled correctly',
        '/user/128.856', 'user 128.856',
            'Str variable at end handled correctly',
        '/user/posts', 'user posts',
            'Longest literal prefix wins',
        '/product/123.456/reviews', 'reviews 123.456',
            'Str variable in middle of literals handled correctly',
        '/product/123.456/reviews/21', 'reviews 123.456 page 21',
            'Having both Str and Int variables handled correctly',
        '/product/123.456/reviews/-21', 'reviews 123.456 page -21',
            'Int may have a sign',
        '/tree', '',
            'Slurpy handled correctly (empty case)',
        '/tree/foo', 'foo',
            'Slurpy handled correctly (one segment case)',
        '/tree/bar/baz', 'bar,baz',
            'Slurpy handled correctly (two segment case)',
        '/tree/gee/wizz/fizz', 'gee,wizz,fizz',
            'Slurpy handled correctly (three segment case)',
        '/orders/history', 'order history (no page)',
            'Optional segment handled correctly (no argument)',
        '/orders/history/2', 'order history (2)',
            'Optional segment handled correctly (argument)',
        '/category/tree', 'category tree none-a none-b',
            'Two optional segments handled correctly (none passed)',
        '/category/tree/foo', 'category tree foo none-b',
            'Two optional segments handled correctly (one passed)',
        '/category/tree/bar/baz', 'category tree bar baz',
            'Two optional segments handled correctly (two passed)';
    for @cases -> $target, $expected-output, $desc {
        $source.emit(Crow::HTTP::Request.new(:method<GET>, :$target));
        given $responses.receive -> $r {
            is-deeply body-text($r), $expected-output, $desc;
        }
    }
}

done-testing;
