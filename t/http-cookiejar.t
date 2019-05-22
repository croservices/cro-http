use Cro::HTTP::Response;
use Cro::HTTP::Request;
use Cro::HTTP::Client::CookieJar;
use Cro::Uri;
use Cro::HTTP::Cookie;
use Test;

my $jar = Cro::HTTP::Client::CookieJar.new;

is $jar.contents, (), 'Empty cookie jar contents returns empty list';
is $jar.contents(Cro::Uri.parse: 'http://example.com'), (), 'Empty cookie jar contents with uri returns empty list';

my $resp = Cro::HTTP::Response.new;
$resp.set-body('Body');
$resp.set-cookie('Foo', 'Bar', path => '/');
$resp.set-cookie('Bar', 'Baz', path => '/');
$resp.set-cookie('Baz', 'Foo', path => '/', expires => DateTime.now.later(hours => 5));

$jar.add-from-response($resp, Cro::Uri.parse: 'http://example.com');

is $jar.contents.elems, 3, 'Two cookies were added';

$jar.add-from-response($resp, Cro::Uri.parse: 'http://example.com');
is $jar.contents.elems, 3, 'Cookie addition is neutral';

$resp.set-cookie('Cookie1', 'Value1', path => '/', domain => 'example.com');
$resp.set-cookie('BadCookie', 'Value2', path => '/', domain => 'example.foo');
$jar.add-from-response($resp, Cro::Uri.parse: 'http://example.com');
is $jar.contents.elems, 4, 'Cookie with bad domain was not added';
is $jar.contents(Cro::Uri.parse: 'http://example.foo').elems, 0, 'Uri-based check';

is $jar.contents(Cro::Uri.parse: 'http://example.com').elems, 4, 'Good cookies are here';

$jar.clear(Cro::Uri.parse: 'http://example.foo');
is $jar.contents.elems, 4, 'Clear for absent url leaves jar untouched';

$jar.clear(Cro::Uri.parse('http://example.foo'), 'Cookie1');
is $jar.contents.elems, 4, 'Clear for absent url with existing cookie name leaves jar untouched';

$jar.clear(Cro::Uri.parse('http://example.com'), 'Foo');
is $jar.contents.elems, 3, 'One cookie was removed';

$jar.clear(Cro::Uri.parse: 'http://example.com');
is $jar.contents.elems, 0, 'All cookies from correct domain were removed';

$jar.add-from-response($resp, Cro::Uri.parse: 'http://example.com');
$jar.clear;
is $jar.contents.elems, 0, 'Call to clear clears cookie jar';

$resp = Cro::HTTP::Response.new;
$resp.set-body('Body');
$resp.set-cookie('Foo', 'Bar', path => '/', max-age => Duration.new: 3600);
$jar.add-from-response($resp, Cro::Uri.parse: 'http://example.com');

my $creation-time = $jar.contents[0].creation-time;

is $jar.contents.elems, 1, 'Cookie with duration was added successfully';

$resp = Cro::HTTP::Response.new;
$resp.set-body('Body');
$resp.set-cookie('Foo', 'Bar', path => '/', max-age => Duration.new: 10);
$jar.add-from-response($resp, Cro::Uri.parse: 'http://example.com');

is $jar.contents[0].creation-time, $creation-time, 'Creation time is preserved during cookie update';


$resp = Cro::HTTP::Response.new;
$resp.set-body('Body');
$resp.set-cookie('Foo', 'Bar', path => '/', max-age => Duration.new: -1);
$jar.add-from-response($resp, Cro::Uri.parse: 'http://example.com');
is $jar.contents.elems, 0, 'Cookie was deleted on negative-time cookie addition';

$resp = Cro::HTTP::Response.new;
$resp.set-body('Body');
$resp.set-cookie('Foo', 'Bar', domain => 'example.com');
$jar.add-from-response($resp, Cro::Uri.parse: 'http://www.example.com/');
is $jar.contents.elems, 1, 'Cookies are added for sub-domains';

$jar.clear;
$resp = Cro::HTTP::Response.new;
$resp.set-body('Body');
$resp.set-cookie('Foo', 'Bar', domain => 'bar.example.com');
$jar.add-from-response($resp, Cro::Uri.parse: 'http://foo.example.com/');
is $jar.contents.elems, 0, 'Rejected for incorrect sub-domain';

$jar.clear;
$resp = Cro::HTTP::Response.new;
$resp.set-body('Body');
$resp.set-cookie('Foo', 'Bar', domain => 'example.com');
$resp.set-cookie('Bar', 'Baz', domain => 'example.com');
$jar.add-from-response($resp, Cro::Uri.parse: 'http://example.com');

my $req = Cro::HTTP::Request.new(method => 'GET', target => '/');
$jar.add-to-request($req, Cro::Uri.parse: 'http://example.com/');
like $req.Str, /Cookie/,  'Header was added';
like $req.Str, /'Foo=Bar; Bar=Baz' || 'Bar=Baz; Foo=Bar'/,  'Set string is correct';

$jar.clear;
$jar.add-cookie(
    Cro::HTTP::Cookie.new(
        name    => 'Test',
        value   => 'Cookie',
        max-age => Duration.new(3600e0),
        domain  => 'example.com',
        path    => '/'
    )
);
is $jar.contents.elems,            1,             'A single cookie was added, successfully';
is $jar.contents[0].cookie.name  , 'Test',        'Added cookie has correct name';
is $jar.contents[0].cookie.value , 'Cookie',      'Added cookie has correct value';
is $jar.contents[0].cookie.domain, 'example.com', 'Added cookie has proper domain';
is $jar.contents[0].cookie.path  , '/',           'Added cookie has proper path';
ok DateTime.now.later(seconds => 3600) - $jar.contents[0].expiry-time <= 1,
    'Cookie has proper expiration time';
# Add cookie with no expiry
$jar.add-cookie(
    Cro::HTTP::Cookie.new(
        name   => 'Test1',
        value  => 'Cookie2',
        domain => 'example.com',
        path   => '/'
    )
);
# Retrieve cookie from jar and check that the expiry is set 10 years later
is $jar.contents.elems,         2,     'A second cookie was added successfully';
is $jar.contents[1].persistent, False, 'New cookie is not persistent';
ok DateTime.now.later(years => 10) - $jar.contents[1].expiry-time <= 1,
    'New cookie has expected expiration time with no max-age set';
$jar.add-to-request($req, Cro::Uri.parse: 'http://example.com/');
like $req.Str, /'Test=Cookie'/, 'First cookie was added to request';
like $req.Str, /'Test1=Cookie2'/, 'Second cookie was added to request';

done-testing;
