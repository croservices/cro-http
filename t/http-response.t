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
}

done-testing;
