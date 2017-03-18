use Crow;
use Crow::HTTP::Request;
use Crow::HTTP::Router;
use Test;

{
    my $app = route -> { }
    ok $app ~~ Crow::Transform, 'Route block gives back a Crow::Transform';
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

done-testing;
