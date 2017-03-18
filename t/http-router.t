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
    }
    ok $app ~~ Crow::Transform, 'Route block with routes gives back a Crow::Transform';
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;

    $source.emit(Crow::HTTP::Request.new(:method<GET>, :target</>));
    given $responses.receive -> $r {
        ok $r ~~ Crow::HTTP::Response, 'Route set with single route gives response';
        is $r.status, 200, 'Got 200 response';
        is $r.header('Content-type'), 'text/html', 'Got expected header';
        is-deeply body-text($r), 'Hello, world', 'Got expected body';
    }
}

done-testing;
