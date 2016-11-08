use Crow::HTTP::Request;
use Test;

{
    my $req = Crow::HTTP::Request.new;
    throws-like { $req.Str }, X::Crow::HTTP::Request::Incomplete,
        'Request missing method and target throws on .Str';
}

{
    my $req = Crow::HTTP::Request.new;
    $req.method = 'GET';
    throws-like { $req.Str }, X::Crow::HTTP::Request::Incomplete,
        'Request missing target throws on .Str';
}

{
    my $req = Crow::HTTP::Request.new;
    $req.target = '/';
    throws-like { $req.Str }, X::Crow::HTTP::Request::Incomplete,
        'Request missing method throws on .Str';
}

{
    my $req = Crow::HTTP::Request.new;
    $req.method = 'GET';
    $req.target = '/';
    is $req.Str, "GET / HTTP/1.1\r\n\r\n",
        'Can serialize simple request built with accessors';
}

{
    my $req = Crow::HTTP::Request.new(method => 'GET', target => '/');
    is $req.Str, "GET / HTTP/1.1\r\n\r\n",
        'Can serialize simple request with method/target in constructor';
}

{
    my $req = Crow::HTTP::Request.new;

    dies-ok { $req.method = 'get' }, 'Lowercase method not allowed';
    dies-ok { $req.method = 'Get' }, 'Mixed case method not allowed';
    dies-ok { $req.method = 'GET PLEASE' }, 'Method with space not allowed';

    dies-ok { $req.target = '/foo bar' }, 'Target with space in not allowed';
    dies-ok { $req.target = "/foo\nbar" }, 'Target with newline in not allowed';
    dies-ok { $req.target = "/foo\abar" }, 'Target with control char not allowed';
    dies-ok { $req.target = "/\c[KATAKANA LETTER A]" },
        'Target with non-Latin-1 characters not allowed';
}

done-testing;
