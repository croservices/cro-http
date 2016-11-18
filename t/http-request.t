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
    is $req.Str, "GET / HTTP/1.0\r\n\r\n",
        'Can serialize simple request built with accessors (HTTP/1.0 with no Host)';
}

{
    my $req = Crow::HTTP::Request.new(method => 'GET', target => '/');
    is $req.Str, "GET / HTTP/1.0\r\n\r\n",
        'Can serialize simple request with method/target in constructor (HTTP/1.0 with no Host)';
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

{
    my $req = Crow::HTTP::Request.new(method => 'GET', target => '/');
    $req.append-header('Host', 'www.moarvm.org');
    is $req.Str, "GET / HTTP/1.1\r\nHost: www.moarvm.org\r\n\r\n",
        'Request with Host header will use HTTP/1.1';
}

{
    my $req = Crow::HTTP::Request.new(method => 'GET', target => '/');
    $req.append-header('Host: www.moarvm.org');
    $req.append-header('Accept-Language: en, mi');
    is $req.Str,
        "GET / HTTP/1.1\r\nHost: www.moarvm.org\r\nAccept-Language: en, mi\r\n\r\n",
        'Request header constructed with single-arg append-header overload works';

    for "\b\n\0\r".comb -> $cc {
        dies-ok { $req.append-header("X-Something: oh{$cc}no") },
            'Refuses to add request header with illegal control char in value (single-arg)';
    }

    for <" ( ) [ ] { } @ \ / \< \> , ;> -> $nope {
        dies-ok { $req.append-header("um{$nope}no: ne") },
            "Refuses to add request header with illegal name containing $nope (single-arg)";
    }

    $req = Crow::HTTP::Request.new(method => 'GET', target => '/');
    $req.append-header('!#42$%omg&\'*+-.wtf^_`~|ReAlLy!!!: oh!"foo\'<>%^&*()[]424242aaáâãäåæµ¥');
    is $req.Str,
        "GET / HTTP/1.0\r\n!#42\$\%omg&'*+-.wtf^_`~|ReAlLy!!!: oh!\"foo'<>%^&*()[]424242aaáâãäåæµ¥\r\n\r\n",
        'Utterly crazy but valid header can be added (single-arg)';
}

{
    my $req = Crow::HTTP::Request.new(method => 'GET', target => '/');
    $req.append-header('Host', 'www.moarvm.org');
    $req.append-header('Accept-Language', 'en, mi');
    is $req.Str,
        "GET / HTTP/1.1\r\nHost: www.moarvm.org\r\nAccept-Language: en, mi\r\n\r\n",
        'Request header constructed with two-arg append-header overload works';

    for "\b\n\0\r".comb -> $cc {
        dies-ok { $req.append-header("X-Something", "oh{$cc}no") },
            'Refuses to add request header with illegal control char in value (two-arg)';
    }

    for <" ( ) [ ] { } @ \ / \< \> , ;> -> $nope {
        dies-ok { $req.append-header("um{$nope}no", "ne") },
            "Refuses to add request header with illegal name containing $nope (two-arg)";
    }

    $req = Crow::HTTP::Request.new(method => 'GET', target => '/');
    $req.append-header('!#42$%omg&\'*+-.wtf^_`~|ReAlLy!!!', 'oh!"foo\'<>%^&*()[]424242aaáâãäåæµ¥');
    is $req.Str,
        "GET / HTTP/1.0\r\n!#42\$\%omg&'*+-.wtf^_`~|ReAlLy!!!: oh!\"foo'<>%^&*()[]424242aaáâãäåæµ¥\r\n\r\n",
        'Utterly crazy but valid header can be added (two-arg)';
}

{
    my $req = Crow::HTTP::Request.new(method => 'GET', target => '/');
    $req.append-header('Accept-Language', 'en, mi');
    is $req.has-header('Accept-Language'), True, 'has-header returns True on header we have';
    is $req.has-header('accept-language'), True, 'has-header is not case-sensitive (1)';
    is $req.has-header('ACCEPT-LANGUAGE'), True, 'has-header is not case-sensitive (2)';
    is $req.has-header('Host'), False, 'has-header returns False on header we do not have';
}

{
    my $req = Crow::HTTP::Request.new(method => 'GET', target => '/');
    $req.append-header('Host', 'www.moarvm.org');
    $req.append-header('Accept-Language', 'en');
    $req.append-header('Accept-Language', 'mi');
    is $req.header('Host'), 'www.moarvm.org', 'header method fetches a header';
    is $req.header('host'), 'www.moarvm.org', 'header method is not case sensitive (1)';
    is $req.header('HOSt'), 'www.moarvm.org', 'header method is not case sensitive (2)';
    is $req.header('Accept-Language'), 'en,mi',
        'when there are multiple headers with the name, the value comma-joins them';
    is $req.header('Content-type'), Nil, 'header we do not have returns Nil';
}

done-testing;
