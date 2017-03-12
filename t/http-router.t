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

done-testing;
