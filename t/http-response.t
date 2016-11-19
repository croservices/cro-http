use Crow::HTTP::Response;
use Test;

{
    my $res = Crow::HTTP::Response.new;
    is $res.Str, "HTTP/1.1 204 No Content\r\n\r\n",
        "Unconfigured HTTP response is HTTP/1.1 and 204 status";

    $res = Crow::HTTP::Response.new(status => 404);
    is $res.Str, "HTTP/1.1 404 Not Found\r\n\r\n",
        "Setting status in constructor includes it in the response";

    $res = Crow::HTTP::Response.new(status => 500, http-version => '1.0');
    is $res.Str, "HTTP/1.0 500 Internal Server Error\r\n\r\n",
        "Setting status and version in constructor includes it in the response";

    $res = Crow::HTTP::Response.new;
    $res.status = 400;
    $res.http-version = '1.0';
    is $res.Str, "HTTP/1.0 400 Bad Request\r\n\r\n",
        "Setting status and version attributes includes them in the response";
}

{
    my $res = Crow::HTTP::Response.new;
    dies-ok { $res.status = 10 }, 'Status of 10 is invalid';
    dies-ok { $res.status = 99 }, 'Status of 99 is invalid';
    dies-ok { $res.status = 1000 }, 'Status of 1000 is invalid';
    dies-ok { $res.status = 4004 }, 'Status of 4004 is invalid';
}

{
    my $res = Crow::HTTP::Response.new(status => 200);
    $res.append-header('Content-type: text/html');
    $res.append-header('Connection', 'close');
    is $res.Str,
        "HTTP/1.1 200 OK\r\nContent-type: text/html\r\nConnection: close\r\n\r\n",
        "Headers are included in the response";
}

done-testing;
