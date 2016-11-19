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

    is $res.has-header('Content-type'), True, 'has-header returns True on header we have';
    is $res.has-header('content-type'), True, 'has-header is not case-sensitive (1)';
    is $res.has-header('CONTENT-TYPE'), True, 'has-header is not case-sensitive (2)';
    is $res.has-header('Server'), False, 'has-header returns False on header we do not have';
    is $res.header('Content-type'), 'text/html', 'header method fetches a header';
    is $res.header('content-type'), 'text/html', 'header method is not case sensitive (1)';
    is $res.header('CONTENT-TYPE'), 'text/html', 'header method is not case sensitive (2)';
    is $res.header('Server'), Nil, 'header method returns Nil on header we do not have';

    for "\b\n\0\r".comb -> $cc {
        dies-ok { $res.append-header("X-Something: oh{$cc}no") },
            'Refuses to add response header with illegal control char in value (single-arg)';
    }
    for "\b\n\0\r".comb -> $cc {
        dies-ok { $res.append-header("X-Something", "oh{$cc}no") },
            'Refuses to add response header with illegal control char in value (two-arg)';
    }

    for <" ( ) [ ] { } @ \ / \< \> , ;> -> $nope {
        dies-ok { $res.append-header("um{$nope}no: ne") },
            "Refuses to add response header with illegal name containing $nope (single-arg)";
    }

    for <" ( ) [ ] { } @ \ / \< \> , ;> -> $nope {
        dies-ok { $res.append-header("um{$nope}no", "ne") },
            "Refuses to add response header with illegal name containing $nope (two-arg)";
    }

    $res = Crow::HTTP::Response.new;
    $res.append-header('!#42$%omg&\'*+-.wtf^_`~|ReAlLy!!!: oh!"foo\'<>%^&*()[]424242aaáâãäåæµ¥');
    is $res.Str,
        "HTTP/1.1 204 No Content\r\n!#42\$\%omg&'*+-.wtf^_`~|ReAlLy!!!: oh!\"foo'<>%^&*()[]424242aaáâãäåæµ¥\r\n\r\n",
        'Utterly crazy but valid header can be added (single-arg)';

    $res = Crow::HTTP::Response.new;
    $res.append-header('!#42$%omg&\'*+-.wtf^_`~|ReAlLy!!!', 'oh!"foo\'<>%^&*()[]424242aaáâãäåæµ¥');
    is $res.Str,
        "HTTP/1.1 204 No Content\r\n!#42\$\%omg&'*+-.wtf^_`~|ReAlLy!!!: oh!\"foo'<>%^&*()[]424242aaáâãäåæµ¥\r\n\r\n",
        'Utterly crazy but valid header can be added (two-arg)';
}

done-testing;
