use Cro::HTTP::Request;
use Cro::MediaType;
use Test;

{
    my $req = Cro::HTTP::Request.new;
    throws-like { $req.Str }, X::Cro::HTTP::Request::Incomplete,
        'Request missing method and target throws on .Str';
}

{
    my $req = Cro::HTTP::Request.new;
    $req.method = 'GET';
    throws-like { $req.Str }, X::Cro::HTTP::Request::Incomplete,
        'Request missing target throws on .Str';
}

{
    my $req = Cro::HTTP::Request.new;
    $req.target = '/';
    throws-like { $req.Str }, X::Cro::HTTP::Request::Incomplete,
        'Request missing method throws on .Str';
}

{
    my $req = Cro::HTTP::Request.new;
    $req.method = 'GET';
    $req.target = '/';
    is $req.Str, "GET / HTTP/1.0\r\n\r\n",
        'Can serialize simple request built with accessors (HTTP/1.0 with no Host)';
}

{
    my $req = Cro::HTTP::Request.new(method => 'GET', target => '/');
    is $req.Str, "GET / HTTP/1.0\r\n\r\n",
        'Can serialize simple request with method/target in constructor (HTTP/1.0 with no Host)';
}

{
    my $req = Cro::HTTP::Request.new;

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
    my $req = Cro::HTTP::Request.new(method => 'GET', target => '/');
    $req.append-header('Host', 'www.moarvm.org');
    is $req.Str, "GET / HTTP/1.1\r\nHost: www.moarvm.org\r\n\r\n",
        'Request with Host header will use HTTP/1.1';
}

{
    my $req = Cro::HTTP::Request.new(method => 'GET', target => '/');
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

    $req = Cro::HTTP::Request.new(method => 'GET', target => '/');
    $req.append-header('!#42$%omg&\'*+-.wtf^_`~|ReAlLy!!!: oh!"foo\'<>%^&*()[]424242aaáâãäåæµ¥');
    is $req.Str,
        "GET / HTTP/1.0\r\n!#42\$\%omg&'*+-.wtf^_`~|ReAlLy!!!: oh!\"foo'<>%^&*()[]424242aaáâãäåæµ¥\r\n\r\n",
        'Utterly crazy but valid header can be added (single-arg)';
}

{
    my $req = Cro::HTTP::Request.new(method => 'GET', target => '/');
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

    $req = Cro::HTTP::Request.new(method => 'GET', target => '/');
    $req.append-header('!#42$%omg&\'*+-.wtf^_`~|ReAlLy!!!', 'oh!"foo\'<>%^&*()[]424242aaáâãäåæµ¥');
    is $req.Str,
        "GET / HTTP/1.0\r\n!#42\$\%omg&'*+-.wtf^_`~|ReAlLy!!!: oh!\"foo'<>%^&*()[]424242aaáâãäåæµ¥\r\n\r\n",
        'Utterly crazy but valid header can be added (two-arg)';
}

{
    my $req = Cro::HTTP::Request.new(method => 'GET', target => '/');
    $req.append-header('Accept-Language', 'en, mi');
    is $req.has-header('Accept-Language'), True, 'has-header returns True on header we have';
    is $req.has-header('accept-language'), True, 'has-header is not case-sensitive (1)';
    is $req.has-header('ACCEPT-LANGUAGE'), True, 'has-header is not case-sensitive (2)';
    is $req.has-header('Host'), False, 'has-header returns False on header we do not have';
}

{
    my $req = Cro::HTTP::Request.new(method => 'GET', target => '/');
    $req.append-header('Host', 'www.moarvm.org');
    $req.append-header('Accept-Language', 'en');
    $req.append-header('Accept-Language', 'mi');
    is $req.header('Host'), 'www.moarvm.org', 'header method fetches a header';
    is $req.header('host'), 'www.moarvm.org', 'header method is not case sensitive (1)';
    is $req.header('HOSt'), 'www.moarvm.org', 'header method is not case sensitive (2)';
    is $req.header('Accept-Language'), 'en,mi',
        'when there are multiple headers with the name, the value comma-joins them';
    is $req.header('Content-type'), Nil, 'header we do not have returns Nil';
    is-deeply $req.header-list('Host'), ('www.moarvm.org',),
        'header-list method returns a List of one header for Host';
    is-deeply $req.header-list('HOST'), ('www.moarvm.org',),
        'header-list method works case-insensitively';
    is-deeply $req.header-list('Accept-language'), ('en', 'mi'),
        'header-list method returns a list of values when there are multiple headers';
    is-deeply $req.header-list('Content-type'), (),
        'header-list methods returns an empty list when no header of the requested name';

    is $req.remove-header('Host'), 1, 'Removing single Host header returns 1';
    is $req.header('Host'), Nil, 'Host header was really removed';
    is $req.remove-header('accept-language'), 2,
        'Removing 2 accept-language headers returns 2';
    is $req.header('Accept-Language'), Nil, 'Headers really removed';

    $req.append-header('Host', 'www.moarvm.org');
    $req.append-header('Accept-Language', 'en');
    $req.append-header('Accept-Language', 'mi');
    is $req.remove-header(*.name.uc eq 'HOST'), 1,
        'Removing single header matched by predicate works';
    is $req.header('Host'), Nil, 'Header identified by predicate was really removed';
    is $req.remove-header($req.headers.tail), 1,
        'Removing an exact header returns 1';
    is $req.header('Accept-Language'), 'en', 'Headers really removed';
}

{
    my $req = Cro::HTTP::Request.new(method => 'GET', target => '/');
    $req.append-header('Content-type', 'text/html; charset=UTF-8');
    ok $req.content-type ~~ Cro::MediaType,
        'content-type method returns a Cro::MediaType when there is a content-type header';
    is $req.content-type.type, 'text', 'Correct type';
    is $req.content-type.subtype, 'html', 'Correct subtype';
    is-deeply $req.content-type.parameters.List, ('charset' => 'UTF-8',),
        'Correct parameters list';

    my $req2 = Cro::HTTP::Request.new(method => 'GET', target => '/');
    is $req2.content-type, Nil, 'content-type returns Nil when no header';
}

{
    my $req = Cro::HTTP::Request.new(method => 'GET', target => '/');
    is $req.has-cookie('Summoning'), False, 'has-cookie on non-existent cookie returns False';
    is $req.cookie-value('Summoning'), Nil, 'cookie-value on non-existent cookie returns Nil';
    is $req.cookie-hash, {}, 'cookie-hash returns empty hash when cookies not set';

    lives-ok { $req.add-cookie('Foo', 'Bar'); }, 'Can add cookie';

    is $req.has-cookie('Foo'), True, 'has-cookie on added cookie returns True';
    is $req.cookie-value('Foo'), 'Bar', 'cookie-value on added cookie returns correct value';
    is $req.cookie-hash, {:Foo<Bar>}, 'cookie-hash returns correct result';

    lives-ok { $req.add-cookie('Foo', 'Baz'); }, 'Can update cookie';
    is $req.has-cookie('Foo'), True, 'has-cookie on updated cookie returns True';
    is $req.cookie-value('Foo'), 'Baz', 'cookie-value on updated cookie returns correct value';

    lives-ok { $req.remove-cookie('Foo'); }, 'Can remove cookie';
    is $req.has-cookie('Foo'), False, 'Removed cookie is removed';

    $req.add-cookie('Foo', 'Bar');
    $req.add-cookie('Lang', 'US');
    dies-ok { $req.add-cookie('', '') }, 'Empty names are not permitted';
    $req.add-cookie('Heaven', 'Valhalla');
    like $req.Str, /"GET / HTTP/1.0\r\nCookie: " ['Foo=Bar' || 'Heaven=Valhalla' || 'Lang=US'] ** 3 % '; '  "\r\n\r\n"/, 'Cookie header looks good';
}

{
    my $req = Cro::HTTP::Request.new(method => 'GET', target => '/');
    $req.append-header('Cookie: foo=WP+Cookie+check;');
    is $req.cookie-value('foo'), 'WP+Cookie+check',
            'Can cope with trailing ; in cookie line';
}

{
    my $req = Cro::HTTP::Request.new(method => 'GET', target => '/products/category/items/');
    is $req.target(), '/products/category/items/', 'Target is set';
    is $req.original-target().Str, '/products/category/items/', 'original-target equals target';
    is $req.original-path().path, '/products/category/items/', 'original-path path equals target';
    is $req.original-path-segments(), $req.path-segments(), 'original-path-segments are equal to target segments';
    my $req2 = $req.without-first-path-segments(1);
    is $req2.target(), '/category/items/', 'target on stripped request changes';
    is $req2.original-target().Str, '/products/category/items/', 'original-target preserves';
    is $req2.original-path().path, '/products/category/items/', 'original-path preserves';
    is $req2.original-path-segments().join('/'), 'products/category/items/', 'original-path-segments are preserved';
    my $req3 = $req2.without-first-path-segments(1);
    is $req3.target(), '/items/', 'target on second stripped request changes';
    is $req3.original-target().Str, '/products/category/items/', 'original-target preserves';
    is $req3.original-path().path, '/products/category/items/', 'original-path preserves';
    is $req3.original-path-segments().join('/'), 'products/category/items/', 'original-path-segments are preserved';
}

done-testing;
