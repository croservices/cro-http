use Cro;
use Cro::HTTP::BodyParser;
use Cro::HTTP::Request;
use Cro::HTTP::Router;
use Test;

sub body-text(Cro::HTTP::Response $r) {
    $r.body-byte-stream.list.map(*.decode('utf-8')).join
}

{
    my $app = route -> { }
    ok $app ~~ Cro::Transform, 'Route block with no routes gives back a Cro::Transform';
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;
    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</>));
    given $responses.receive -> $r {
        ok $r ~~ Cro::HTTP::Response, 'Empty route set gives a response';
        is $r.status, '404', 'Status code from empty route set is 404';
    }
}

throws-like { request }, X::Cro::HTTP::Router::OnlyInHandler, what => 'request',
    'Can only use request term inside of a handler';
throws-like { response }, X::Cro::HTTP::Router::OnlyInHandler, what => 'response',
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
    ok $app ~~ Cro::Transform, 'Route block with routes gives back a Cro::Transform';
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</>));
    given $responses.receive -> $r {
        ok $r ~~ Cro::HTTP::Response, 'Route set routes / correctly';
        is $r.status, 200, 'Got 200 response';
        is $r.header('Content-type'), 'text/html', 'Got expected header';
        is-deeply body-text($r), 'Hello, world', 'Got expected body';
    }

    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</about>));
    given $responses.receive -> $r {
        ok $r ~~ Cro::HTTP::Response, 'Route set routes /about correctly';
        is $r.status, 200, 'Got 200 response';
        is $r.header('Content-type'), 'text/html', 'Got expected header';
        is-deeply body-text($r), 'We are the awesome', 'Got expected body';
    }

    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</company/careers>));
    given $responses.receive -> $r {
        ok $r ~~ Cro::HTTP::Response, 'Route set routes /company/careers correctly';
        is $r.status, 200, 'Got 200 response';
        is $r.header('Content-type'), 'text/html', 'Got expected header';
        is-deeply body-text($r), 'No jobs, kthxbai', 'Got expected body';
    }

    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</wat>));
    given $responses.receive -> $r {
        ok $r ~~ Cro::HTTP::Response, 'No matching route gets a HTTP response';
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

    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</product>));
    given $responses.receive -> $r {
        ok $r ~~ Cro::HTTP::Response, 'Route set routes GET';
        is $r.status, 200, 'Got 200 response';
        is $r.header('Content-type'), 'text/html', 'Got expected header';
        is-deeply body-text($r), 'A GET request', 'Got expected body';
    }

    $source.emit(Cro::HTTP::Request.new(:method<POST>, :target</product>));
    given $responses.receive -> $r {
        ok $r ~~ Cro::HTTP::Response, 'Route set routes POST';
        is $r.status, 201, 'Got 201 response';
        is $r.header('Content-type'), 'text/html', 'Got expected header';
        is-deeply body-text($r), 'A POST request', 'Got expected body';
    }

    $source.emit(Cro::HTTP::Request.new(:method<PUT>, :target</product>));
    given $responses.receive -> $r {
        ok $r ~~ Cro::HTTP::Response, 'Route set routes PUT';
        is $r.status, 204, 'Got 204 response';
    }

    $source.emit(Cro::HTTP::Request.new(:method<DELETE>, :target</product>));
    given $responses.receive -> $r {
        ok $r ~~ Cro::HTTP::Response, 'Route set routes DELETE';
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
        $source.emit(Cro::HTTP::Request.new(:method<GET>, :$target));
        given $responses.receive -> $r {
            is-deeply body-text($r), $expected-output, $desc;
        }
    }
}

{
    my $app = route {
        get -> 'search', :$min-price is query = 0, :$max-price is query = Inf {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("search $min-price .. $max-price".encode('ascii'));
        }

        get -> 'headertest1', :$x-custom1 is header = 'x', :$x-custom3 is header = 'x' {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("headertest1 $x-custom1 $x-custom3".encode('ascii'));
        }

        get -> 'headertest2', :$x-custom2 is header = 'x', :$x-custom1 is header = 'x' {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("headertest2 $x-custom1 $x-custom2".encode('ascii'));
        }

        get -> 'headertest3', :$X-CUSTOM1 is header = 'x', :$X-cusTom2 is header = 'x' {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("headertest3 $X-CUSTOM1 $X-cusTom2".encode('ascii'));
        }

        get -> 'reqquery', :$field1! is query {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("reqquery field1".encode('ascii'));
        }

        get -> 'reqquery', :$field2! is query {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("reqquery field2".encode('ascii'));
        }

        get -> 'reqheader', :$unknown! is header {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("reqheader unknown".encode('ascii'));
        }

        get -> 'reqheader', :$x-custom1! is header {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("reqheader x-custom1".encode('ascii'));
        }

        get -> 'reqintarg', Int :$page! is query {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("reqintarg $page".encode('ascii'));
        }

        get -> 'optintarg', Int :$page is query = 1 {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("optintarg $page".encode('ascii'));
        }
    }
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    my @cases =
        '/search', 'search 0 .. Inf',
            'Two query string parameters, neither passed (explicit is query)',
        '/search?min-price=50', 'search 50 .. Inf',
            'Two query string parameters, first passed (explicit is query)',
        '/search?max-price=100', 'search 0 .. 100',
            'Two query string parameters, second passed (explicit is query)',
        '/search?max-price=60&min-price=20', 'search 20 .. 60',
            'Two query string parameters, both passed (explicit is query)',
        '/headertest1', 'headertest1 c1 x',
            'Two header parameters, one for a non-present header',
        '/headertest2', 'headertest2 c1 c2',
            'Two header parameters, both present',
        '/headertest3', 'headertest3 c1 c2',
            'Header parameters are case-insensitive',
        '/reqquery?field1=x', 'reqquery field1',
            'Required query parameter selects correct route (1)',
        '/reqquery?field2=x', 'reqquery field2',
            'Required query parameter selects correct route (2)',
        '/reqquery?field1=x&field2=x', 'reqquery field1',
            'First winning route with required query items wins',
        '/reqheader', 'reqheader x-custom1',
            'Correct route picked when there are required headers',
        '/reqintarg?page=42', 'reqintarg 42',
            'Route with required Int named arg for query parameter works',
        '/optintarg?page=100', 'optintarg 100',
            'Route with optional Int named arg for query parameter works when passed',
        '/optintarg', 'optintarg 1',
            'Route with optional Int named arg for query parameter works when not passed';
    for @cases -> $target, $expected-output, $desc {
        my $req = Cro::HTTP::Request.new(:method<GET>, :$target);
        $req.append-header('X-Custom1', 'c1');
        $req.append-header('X-Custom2', 'c2');
        $source.emit($req);
        given $responses.receive -> $r {
            is-deeply body-text($r), $expected-output, $desc;
        }
    }
}

{
    my subset UUIDv4 of Str where /^
        <[0..9a..f]> ** 12
        4 <[0..9a..f]> ** 3
        <[89ab]> <[0..9a..f]> ** 15
        $/;
    my subset Percent of Int where 1..100;
    my $app = route {
        get -> 'product', UUIDv4 $id {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("product $id".encode('ascii'));
        }

        get -> 'chart', Percent $complete {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("percent $complete".encode('ascii'));
        }

        get -> 'tag', $tag where /^\w+$/ {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("tag $tag".encode('ascii'));
        }

        get -> 'advent', Int $day where * <= 24 {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("advent $day".encode('ascii'));
        }
    }
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    my @good-cases =
        '/product/673c748325a3411d871ccf969751f0de', 'product 673c748325a3411d871ccf969751f0de',
            'Segment constrained by Str-base subset type matches when it should',
        '/chart/50', 'percent 50',
            'Segment constrained by Int-base subset type matches when it should',
        '/tag/pizza', 'tag pizza',
            'Segment constrained by where clause matches when it should',
        '/advent/13', 'advent 13',
            'Segment of type Int constrained by where clause matches when it should';
    for @good-cases -> $target, $expected-output, $desc {
        my $req = Cro::HTTP::Request.new(:method<GET>, :$target);
        $source.emit($req);
        given $responses.receive -> $r {
            is-deeply body-text($r), $expected-output, $desc;
        }
    }

    my @bad-cases =
        '/product/not-a-uuid', 404, 'Non-matching segment gives 404 error (subset, Str)',
        '/percent/1000', 404, 'Non-matching segment gives 404 error (subset, Int)',
        '/tag/not-valid', 404, 'Non-matching segment gives 404 error (where, Str)',
        '/advent/25', 404, 'Non-matching segment gives 404 error (where, Int)';
    for @bad-cases -> $target, $expected-status, $desc {
        my $req = Cro::HTTP::Request.new(:method<GET>, :$target);
        $source.emit($req);
        given $responses.receive -> $r {
            is $r.status, $expected-status, $desc;
        }
    }
}

{
    my subset UUIDv4 of Str where /^
        <[0..9a..f]> ** 12
        4 <[0..9a..f]> ** 3
        <[89ab]> <[0..9a..f]> ** 15
        $/;
    my subset Percent of Int where 1..100;
    my $app = route {
        get -> 'orders', UUIDv4 :$id! is query {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("order $id".encode('ascii'));
        }

        my constant DEFAULT_SESSION = '6419c8383038446bb3e95d0302dd4942';
        get -> 'home', UUIDv4 :$session is query = DEFAULT_SESSION {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("home $session".encode('ascii'));
        }

        get -> 'chart', Percent :$percent! is query {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("chart $percent".encode('ascii'));
        }

        get -> 'loan', Percent :$deposit is query = 15 {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("loan $deposit".encode('ascii'));
        }

        get -> 'tag', :$tag! is query where /^\w+$/ {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("tag $tag".encode('ascii'));
        }

        get -> 'advent', Int :$day! is query where * <= 24 {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body("advent $day".encode('ascii'));
        }
    };
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    my @good-cases =
        '/orders?id=673c748325a3411d871ccf969751f0de', 'order 673c748325a3411d871ccf969751f0de',
            'Required unpack constrained by Str-base subset type works',
        '/home?session=673c748325a3411d871ccf969751f0de', 'home 673c748325a3411d871ccf969751f0de',
            'Optional unpack constrained by Str-base subset type works (provided)',
        '/home', 'home 6419c8383038446bb3e95d0302dd4942',
            'Optional unpack constrained by Str-base subset type works (not provided)',
        '/chart?percent=50', 'chart 50',
            'Required unpack constrained by Int-base subset type works',
        '/loan?deposit=10', 'loan 10',
            'Optional unpack constrained by Int-base subset type works (provided)',
        '/loan', 'loan 15',
            'Optional unpack constrained by Int-base subset type works (not provided)',
        '/tag?tag=soup', 'tag soup',
            'Required unpack untyped with where constraint works',
        '/advent?day=10', 'advent 10',
            'Required unpack of type Int with where constraint works';
    for @good-cases -> $target, $expected-output, $desc {
        my $req = Cro::HTTP::Request.new(:method<GET>, :$target);
        $source.emit($req);
        given $responses.receive -> $r {
            is-deeply body-text($r), $expected-output, $desc;
        }
    }

    my @bad-cases =
        '/orders', 400, 'Missing unpack gives 400 error (subset, Str)',
        '/orders?id=lol', 400, 'Non-matching unpack gives 400 error (subset, Str)',
        '/home?session=lol', 400, 'Non-matching optional unpack gives 400 error (subset, Str)',
        '/chart', 400, 'Missing unpack gives 400 error (subset, Int)',
        '/chart?percent=200', 400, 'Non-matching unpack gives 400 error (subset, Int)',
        '/loan?deposit=1000', 400, 'Non-matching optional unpack gives 400 error (subset, Int)',
        '/tag', 400, 'Missing unpack gives 400 error (where, Str)',
        '/tag?tag=abc-def', 400, 'Non-matching unpack gives 400 error (where, Str)',
        '/advent', 400, 'Missing unpack gives 400 error (where, Int)',
        '/tag?day=26', 400, 'Non-matching unpack gives 400 error (where, Int)';
    for @bad-cases -> $target, $expected-status, $desc {
        my $req = Cro::HTTP::Request.new(:method<GET>, :$target);
        $source.emit($req);
        given $responses.receive -> $r {
            is $r.status, $expected-status, $desc;
        }
    }
}

{
    my $app = route {
        get -> {
            response.status = 200;
            response.append-header('Content-type', 'text/html');
            response.set-body('Hello, world'.encode('ascii'));
        }
    }
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    for <PUT POST DELETE> -> $method {
        my $req = Cro::HTTP::Request.new(:$method, :target</>);
        $source.emit($req);
        given $responses.receive -> $r {
            is $r.status, 405, 'URL that matches on segments but not method is 405';
        }
    }
}

{
    my $app = route {
        get -> 'blob-body' {
            content 'application/octet-stream', Blob.new(103, 114, 114);
        }

        get -> 'str-body-no-accept-charset' {
            content 'text/html', '<strong>Bears!</strong>';
        }

        get -> 'headers' {
            header 'Link', '/honey; rel=food';
            header 'Link: /den; rel=hibernate';
            content 'application/json', '{ "bear": "grr" }';
        }

        get -> 'reminders', :$task! is query {
            created '/reminders/1';
            content 'text/plain', $task;
        }

        get -> 'shopping-list', :$product! is query {
            created '/shopping-list/1', 'text/plain', $product;
        }

        get -> 'latin-1' {
            content 'text/plain', 'wow not utf-8', :enc<ISO-8859-1>;
        }
    }
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</blob-body>);
        $source.emit($req);
        given $responses.receive -> $r {
            is $r.status, 200, 'Simple binary content response has 200 status';
            is $r.header('Content-type'), 'application/octet-stream',
                'Correct content-type set';
            is body-text($r), 'grr', 'Got expected body';
        }
    }

    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</str-body-no-accept-charset>);
        $source.emit($req);
        given $responses.receive -> $r {
            is $r.status, 200, 'Simple text content response has 200 status';
            is $r.header('Content-type'), 'text/html; charset=utf-8',
                'Correct content-type set including charset';
            is body-text($r), '<strong>Bears!</strong>', 'Got expected body';
        }
    }

    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</headers>);
        $source.emit($req);
        given $responses.receive -> $r {
            is $r.status, 200, 'Simple JSON content response has 200 status';
            my @link = $r.headers.grep(*.name.lc eq 'link');
            is @link.elems, 2, 'Got two Link headers';
            is @link.grep(*.value eq '/honey; rel=food').elems, 1,
                'Got expected link header value (1)';
            is @link.grep(*.value eq '/den; rel=hibernate').elems, 1,
                'Got expected link header value (2)';
            is $r.header('Content-type'), 'application/json; charset=utf-8',
                'Correct content-type set including charset';
            is body-text($r), '{ "bear": "grr" }', 'Got expected body';
        }
    }

    {
        my $req = Cro::HTTP::Request.new(:method<GET>,
            :target</reminders?task=shave>);
        $source.emit($req);
        given $responses.receive -> $r {
            is $r.status, 201, 'created + content response has 201 status';
            is $r.header('Location'), '/reminders/1', 'Location header is set';
            is $r.header('Content-type'), 'text/plain; charset=utf-8',
                'Correct content-type set including charset';
            is body-text($r), 'shave', 'Got expected body';
        }
    }

    {
        my $req = Cro::HTTP::Request.new(:method<GET>,
            :target</shopping-list?product=beef>);
        $source.emit($req);
        given $responses.receive -> $r {
            is $r.status, 201, 'created response has 201 status';
            is $r.header('Location'), '/shopping-list/1', 'Location header is set';
            is $r.header('Content-type'), 'text/plain; charset=utf-8',
                'Correct content-type set including charset';
            is body-text($r), 'beef', 'Got expected body';
        }
    }

    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</latin-1>);
        $source.emit($req);
        given $responses.receive -> $r {
            is $r.status, 200, 'Str content with :enc<ISO-8859-1> has 200 response';
            is $r.header('Content-type'), 'text/plain; charset=ISO-8859-1',
                'Correct content-type with charset=ISO-8859-1';
            is body-text($r), 'wow not utf-8', 'Got expected body';
        }
    }
}

{
    my $app = route {
        get -> 'not-found-1', $id {
            if $id == 1 {
                content 'text/plain', 'found ok';
            }
            else {
                not-found;
                content 'text/plain', '404 not found';
            }
        }

        get -> 'not-found-2', $id {
            if $id == 1 {
                content 'text/plain', 'found ok!';
            }
            else {
                not-found 'text/plain', '404 not found!';
            }
        }

        get -> 'bad-request-1', $id {
            if $id == 1 {
                content 'text/plain', 'request ok';
            }
            else {
                bad-request;
                content 'text/plain', '400 bad request';
            }
        }

        get -> 'bad-request-2', $id {
            if $id == 1 {
                content 'text/plain', 'request ok!';
            }
            else {
                bad-request 'text/plain', '400 bad request!';
            }
        }

        get -> 'forbidden-1', $id {
            if $id == 1 {
                content 'text/plain', 'request allowed';
            }
            else {
                forbidden;
                content 'text/plain', '403 forbidden';
            }
        }

        get -> 'forbidden-2', $id {
            if $id == 1 {
                content 'text/plain', 'request allowed!';
            }
            else {
                forbidden 'text/plain', '403 forbidden!';
            }
        }

        get -> 'conflict-1', $id {
            if $id == 1 {
                content 'text/plain', 'request timely';
            }
            else {
                conflict;
                content 'text/plain', '409 conflict';
            }
        }

        get -> 'conflict-2', $id {
            if $id == 1 {
                content 'text/plain', 'request timely!';
            }
            else {
                conflict 'text/plain', '409 conflict!';
            }
        }
    }
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    my @cases =
        '/not-found-1/1', 200, 'found ok', 'not found sanity (1)',
        '/not-found-1/6', 404, '404 not found', 'not found (1)',
        '/not-found-2/1', 200, 'found ok!', 'not found sanity (2)',
        '/not-found-2/6', 404, '404 not found!', 'not found (2)',
        '/bad-request-1/1', 200, 'request ok', 'bad request sanity (1)',
        '/bad-request-1/6', 400, '400 bad request', 'bad request (1)',
        '/bad-request-2/1', 200, 'request ok!', 'bad request sanity (2)',
        '/bad-request-2/6', 400, '400 bad request!', 'bad request (2)',
        '/forbidden-1/1', 200, 'request allowed', 'forbidden sanity (1)',
        '/forbidden-1/6', 403, '403 forbidden', 'forbidden (1)',
        '/forbidden-2/1', 200, 'request allowed!', 'forbidden sanity (2)',
        '/forbidden-2/6', 403, '403 forbidden!', 'forbidden (2)',
        '/conflict-1/1', 200, 'request timely', 'conflict sanity (1)',
        '/conflict-1/6', 409, '409 conflict', 'conflict (1)',
        '/conflict-2/1', 200, 'request timely!', 'conflict sanity (2)',
        '/conflict-2/6', 409, '409 conflict!', 'conflict (2)';
    for @cases -> $target, $status, $body, $desc {
        my $req = Cro::HTTP::Request.new(:method<GET>, :$target);
        $source.emit($req);
        given $responses.receive -> $r {
            is $r.status, $status, "Error routine $desc - status";
            is $r.header('Content-type'), 'text/plain; charset=utf-8',
                "Error routine $desc - content type";
            is body-text($r), $body, "Error routine $desc - body";
        }
    }
}

{
    my $app = route {
        get -> 'redir', 'temp-1' {
            redirect '/to/temp-1';
            content 'text/html', '<a href="/to/temp-1">Click here</a>';
        }

        get -> 'redir', 'temp-2' {
            redirect '/to/temp-2', 'text/html',
                '<a href="/to/temp-2">Click here</a>'
        }

        get -> 'redir', 'temp-3' {
            redirect :temporary, '/to/temp-3';
            content 'text/html', '<a href="/to/temp-3">Click here</a>';
        }

        get -> 'redir', 'temp-4' {
            redirect :temporary, '/to/temp-4', 'text/html',
                '<a href="/to/temp-4">Click here</a>'
        }

        get -> 'redir', 'perm-1' {
            redirect :permanent, '/to/perm-1';
            content 'text/html', '<a href="/to/perm-1">Click here</a>';
        }

        get -> 'redir', 'perm-2' {
            redirect :permanent, '/to/perm-2', 'text/html',
                '<a href="/to/perm-2">Click here</a>'
        }

        get -> 'redir', 'see-other-1' {
            redirect :see-other, '/to/see-other-1';
            content 'text/html', '<a href="/to/see-other-1">Click here</a>';
        }

        get -> 'redir', 'see-other-2' {
            redirect :see-other, '/to/see-other-2', 'text/html',
                '<a href="/to/see-other-2">Click here</a>'
        }
    }
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    my @cases =
        '/redir/temp-1', 307, '/to/temp-1', 'Temporary redirect (1)',
        '/redir/temp-2', 307, '/to/temp-2', 'Temporary redirect (2)',
        '/redir/temp-3', 307, '/to/temp-3', 'Temporary redirect (3)',
        '/redir/temp-4', 307, '/to/temp-4', 'Temporary redirect (4)',
        '/redir/perm-1', 308, '/to/perm-1', 'Permanent redirect (1)',
        '/redir/perm-2', 308, '/to/perm-2', 'Permanent redirect (2)',
        '/redir/see-other-1', 303, '/to/see-other-1', 'See other redirect (1)',
        '/redir/see-other-2', 303, '/to/see-other-2', 'See other redirect (2)';
    for @cases -> $target, $status, $location, $desc {
        my $req = Cro::HTTP::Request.new(:method<GET>, :$target);
        $source.emit($req);
        given $responses.receive -> $r {
            is $r.status, $status, "$desc - status";
            is $r.header('Content-type'), 'text/html; charset=utf-8',
                "$desc - content type";
            is $r.header('Location'), $location, "$desc - location";
            is body-text($r), q:s{<a href="$location">Click here</a>},
                "$desc - body";
        }
    }
}

{
    my $app = route {
        get -> 'use-request' {
            content 'text/plain', request.header('X-Testing');
        }
    }
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    my $req = Cro::HTTP::Request.new(:method<GET>, :target</use-request>);
    $req.append-header('X-Testing', 'Yes it works');
    $source.emit($req);
    given $responses.receive -> $r {
        is body-text($r), 'Yes it works', 'Can use request inside of a handler';
    }
}

{
    my $app = route {
        get -> 'blob' {
            request-body-blob -> $blob {
                content 'text/plain', "blob: {$blob ~~ Blob}, $blob.elems()"
            }
        }

        get -> 'text' {
            request-body-text -> $text {
                content 'text/plain', "text: {$text ~~ Str}, $text.chars()"
            }
        }

        get -> 'body' {
            request-body -> $body {
                content 'text/plain', "body: city is $body<city>, rooms is $body<rooms>";
            }
        }

        get -> 'pair' {
            request-body 'application/json' => -> $body {
                content 'text/plain', "pair: x is $body<x>, y is $body<y>";
            }
        }

        get -> 'list' {
            request-body
                'application/json' => -> $body {
                    content 'text/plain', "list(json): x is $body<x>, y is $body<y>";
                },
                'text/plain' => -> $body {
                    content 'text/plain', "list(text): $body";
                },
                {
                    content 'text/plain', "list(unknown)";
                }
        }

        get -> 'bysig' {
            request-body
                "application/json" => -> (:$x, :$y where $y > $x) {
                    content 'text/plain', "bysig($y > $x)";
                },
                -> (:$x, :$y where $y <= $x) {
                    content 'text/plain', "bysig($y <= $x)";
                };
        }
    }
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    my $test-body-stream = supply { emit 'city=Praha&rooms=2'.encode('ascii') }
    my $test-body-length = 18;

    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</blob>);
        $req.append-header('Content-type', 'application/x-www-form-urlencoded');
        $req.append-header('Content-length', $test-body-length);
        $req.set-body-byte-stream($test-body-stream);
        $source.emit($req);
        given $responses.receive -> $r {
            is body-text($r), 'blob: True, 18',
                'request-body-blob passed a block invokes it with the body blob';
        }
    }

    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</text>);
        $req.append-header('Content-type', 'application/x-www-form-urlencoded');
        $req.append-header('Content-length', $test-body-length);
        $req.set-body-byte-stream($test-body-stream);
        $source.emit($req);
        given $responses.receive -> $r {
            is body-text($r), 'text: True, 18',
                'request-body-text passed a block invokes it with the body text';
        }
    }

    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</body>);
        $req.append-header('Content-type', 'application/x-www-form-urlencoded');
        $req.append-header('Content-length', $test-body-length);
        $req.set-body-byte-stream($test-body-stream);
        $source.emit($req);
        given $responses.receive -> $r {
            is body-text($r), 'body: city is Praha, rooms is 2',
                'request-body passed a block invokes it with the body object';
        }
    }

    my $json-body-stream = supply { emit '{"x":42,"y":101}'.encode('ascii') }
    my $json-body-length = 16;

    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</pair>);
        $req.append-header('Content-type', 'application/json; charset="UTF-8"');
        $req.append-header('Content-length', $json-body-length);
        $req.set-body-byte-stream($json-body-stream);
        $source.emit($req);
        given $responses.receive -> $r {
            is body-text($r), 'pair: x is 42, y is 101',
                'request-body passed a pair invokes block when content type matches';
        }
    }

    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</pair>);
        $req.append-header('Content-type', 'application/vnd.me+json; charset="UTF-8"');
        $req.append-header('Content-length', $json-body-length);
        $req.set-body-byte-stream($json-body-stream);
        $source.emit($req);
        given $responses.receive -> $r {
            is $r.status, '400', 'When no body match, get bad request response';
        }
    }

    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</list>);
        $req.append-header('Content-type', 'application/json; charset="UTF-8"');
        $req.append-header('Content-length', $json-body-length);
        $req.set-body-byte-stream($json-body-stream);
        $source.emit($req);
        given $responses.receive -> $r {
            is body-text($r), 'list(json): x is 42, y is 101',
                'request-body passed a list chooses first Pair if there is a match';
        }
    }

    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</list>);
        $req.append-header('Content-type', 'text/plain; charset="UTF-8"');
        $req.append-header('Content-length', $json-body-length);
        $req.set-body-byte-stream($json-body-stream);
        $source.emit($req);
        given $responses.receive -> $r {
            is body-text($r), 'list(text): {"x":42,"y":101}',
                'request-body passed a list chooses second Pair if there is a match';
        }
    }

    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</list>);
        $req.append-header('Content-type', 'application/x-mystery; charset="UTF-8"');
        $req.append-header('Content-length', $json-body-length);
        $req.set-body-byte-stream($json-body-stream);
        $source.emit($req);
        given $responses.receive -> $r {
            is body-text($r), 'list(unknown)',
                'request-body passed a list chooses final block if no earlier pairs match';
        }
    }

    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</bysig>);
        $req.append-header('Content-type', 'application/json; charset="UTF-8"');
        $req.append-header('Content-length', $json-body-length);
        $req.set-body-byte-stream($json-body-stream);
        $source.emit($req);
        given $responses.receive -> $r {
            is body-text($r), 'bysig(101 > 42)',
                'request-body matches by signature (Pair case)';
        }
    }

    my $json-body-stream-b = supply { emit '{"x":142,"y":10}'.encode('ascii') }
    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</bysig>);
        $req.append-header('Content-type', 'application/json; charset="UTF-8"');
        $req.append-header('Content-length', $json-body-length);
        $req.set-body-byte-stream($json-body-stream-b);
        $source.emit($req);
        given $responses.receive -> $r {
            is body-text($r), 'bysig(10 <= 142)',
                'request-body matches by signature (Block case)';
        }
    }
}

{
    my class TestBody {
        has $.content;
    }

    my class TestBodyParser does Cro::HTTP::BodyParser {
        method is-applicable(Cro::HTTP::Message $message --> Bool) {
            with $message.content-type {
                .type eq 'text' && .subtype eq 'x-test'
            }
            else {
                False
            }
        }
        method parse(Cro::HTTP::Message $message --> Promise) {
            $message.body-text.then({ TestBody.new(content => .result) })
        }
    }

    my $app = route {
        body-parser TestBodyParser;

        get -> 'parser' {
            request-body -> $body {
                content 'text/plain', "test-parser: $body.^name(), $body.content()";
            }
        }

        get -> 'prepend' {
            request-body 'application/json' => -> $body {
                content 'text/plain', "prepend: x is $body<x>, y is $body<y>";
            }
        }
    }
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</parser>);
        $req.append-header('Content-type', 'text/x-test');
        $req.append-header('Content-length', 13);
        $req.set-body-byte-stream(supply { emit 'cabbage candy'.encode('ascii') });
        $source.emit($req);
        given $responses.receive -> $r {
            is body-text($r), 'test-parser: TestBody, cabbage candy',
                'body-parser installs a new body parser and it is used';
        }
    }

    {
        my $req = Cro::HTTP::Request.new(:method<GET>, :target</prepend>);
        $req.append-header('Content-type', 'application/json; charset="UTF-8"');
        $req.append-header('Content-length', 16);
        $req.set-body-byte-stream(supply { emit '{"x":42,"y":101}'.encode('ascii') });
        $source.emit($req);
        given $responses.receive -> $r {
            is body-text($r), 'prepend: x is 42, y is 101',
                'body-parser leaves existing body parsers in place';
        }
    }
}

done-testing;
