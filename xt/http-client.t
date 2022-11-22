use v6.d;
use Base64;
use Cro::HTTP::Client;
use Cro::HTTP::Client::CookieJar;
use Cro::HTTP::Response;
use Cro::TLS;
use Test;

constant HTTP_TEST_PORT = 31316;
constant HTTPS_TEST_PORT = 31317;
constant PROXY_TEST_PORT = 31318;
constant ROOT_REDIRECT_TEST_PORT = 31330;
constant %ca := { ca-file => 'xt/certs-and-keys/ca-crt.pem' };
constant %key-cert := {
    private-key-file => 'xt/certs-and-keys/server-key.pem',
    certificate-file => 'xt/certs-and-keys/server-crt.pem'
};

# Proxy server
{
    use Cro::Transform;
    use Cro::TCP;

    class Proxy does Cro::Transform {
        method consumes() { Cro::TCP::Message }
        method produces() { Cro::TCP::Message }

        method transformer(Supply $source) {
            supply {
                whenever $source -> $message {
                    my $data = ("HTTP/1.1 200 OK\r\nContent-Length: {$message.data.elems}\r\n\r\n" ~ $message.data.decode).encode('ascii');
                    emit Cro::TCP::Message.new(:$data, :connection($message.connection));
                }
            }
        }
    }

    my Cro::Service $proxy-server = Cro.compose(
        Cro::TCP::Listener.new(port => PROXY_TEST_PORT),
        Proxy,
    );
    $proxy-server.start();
    END $proxy-server.stop();
}

# Test application.
{
    use Cro::HTTP::Router;
    use Cro::HTTP::Server;

    my $app = route {
        get -> {
            content 'text/plain', 'Home';
        }
        post -> {
            content 'text/plain', 'Updated';
        }
        put -> {
            content 'text/plain', 'Saved';
        }
        delete -> {
            content 'text/plain', 'Gone';
        }
        patch -> {
            content 'text/plain', 'Patched';
        }
        get -> 'query', :$value {
            content 'text/plain', $value ?? $value.uc !! "No Query";
        }
        get -> 'json' {
            request-body -> %json {
                content 'text/plain', "%json<reason>";
            }
        }
        get -> 'get-json' {
            content 'application/json', {:42truth};
        }
        get -> 'str' {
            request-body-text -> $str {
                content 'text/plain', "$str";
            }
        }
        post -> 'str', :%headers is header {
            request-body-text -> $str {
                content 'text/plain', "$str - %headers<Content-length>";
            }
        }
        get -> 'blob' {
            request-body-blob -> $blob {
                content 'image/jpeg', $blob.reverse;
            }
        }
        get -> 'urlencoded' {
            request-body -> $body {
                content 'text/plain', "Welcome, {$body.hash<name>} {$body.hash<surname>}!";
            }
        }
        get -> 'multipart' {
            request-body -> $body {
                if $body ~~ Cro::HTTP::Body::MultiPartFormData
                && $body.parts[2].filename eq 'secret.jpg' {
                    content 'text/plain', "You are cute!";
                }
            }
        }
        get -> 'path', :$User-agent! is header {
            content 'text/plain', "When you are $User-agent, it is fine to request";
        }
        get -> 'error' {
            given response {
                $_.status = 500;
            }
        }

        # Cookie section
        get -> 'cookie-one', :$First! is cookie {
            content 'text/plain', 'First was sent';
        }
        get -> 'cookie-one' {
            set-cookie 'First', 'Done';
            content 'text/plain', 'First is set';
        }
        get -> 'cookie-two', :$Second! is cookie {
            content 'text/plain', 'Second was sent';
        }
        get -> 'cookie-two' {
            set-cookie 'Second', 'Done';
            content 'text/plain', 'Second is set';
        }
        get -> 'cookie-three', :$First! is cookie, :$Second! is cookie {
            content 'text/plain', 'Cookies are present';
        }
        get -> 'eternal-redirect' {
            redirect :permanent, "http://localhost:{HTTP_TEST_PORT}/eternal-redirect";
        }
        get -> 'single-redirect' {
            redirect :permanent, "http://localhost:{HTTP_TEST_PORT}/str";
        }
        post -> 'get-303' {
            redirect :see-other, "http://localhost:{HTTP_TEST_PORT}/";
        }
        post -> 'post-307' {
            redirect :permanent, "http://localhost:{HTTP_TEST_PORT}/str";
        }
        post -> 'post-307-relative' {
            redirect :permanent, "/str";
        }
        get -> 'auth-echo', :$Authorization! is header {
            content 'text/plain', "$Authorization";
        }
        get -> 'auth-echo', {
            response.status = 401;
        }

        # Query string handling section
        get -> 'query-string', :$x, :$y {
            content 'text/plain', "x = $x, y = $y";
        }
    }

    my $http-server = Cro::HTTP::Server.new(
        port => HTTP_TEST_PORT,
        application => $app
    );
    $http-server.start();
    END $http-server.stop();

    my $https-server = Cro::HTTP::Server.new(
        port => HTTPS_TEST_PORT,
        application => $app,
        tls => %key-cert
    );
    $https-server.start();
    END $https-server.stop();
}

{
    use Cro::HTTP::Router;
    use Cro::HTTP::Server;

    my $app = route {
        get -> {
            redirect '/ok';
        }
        get -> 'ok' {
            content 'text/plain', 'ok';
        }
    }
    my $http-server = Cro::HTTP::Server.new:
            port => ROOT_REDIRECT_TEST_PORT,
            application => $app;
    $http-server.start();
    END $http-server.stop();
}

{
    {
        (temp %*ENV)<HTTP_PROXY HTTPS_PROXY NO_PROXY> = flat "http://localhost:{PROXY_TEST_PORT}" xx 2, '';
        # HTTP case
        given await Cro::HTTP::Client.get("http://localhost:{HTTP_TEST_PORT}/") -> $resp {
            my @lines = (await $resp.body).decode.lines[^2];
            is @lines[0], "GET http://localhost:31316/ HTTP/1.1";
            is @lines[1], "Host: localhost:31316";
        }

        # HTTPS case
        given await Cro::HTTP::Client.get("https://localhost:{HTTP_TEST_PORT}/") -> $resp {
            my @lines = (await $resp.body).decode.lines[^2];
            is @lines[0], "GET https://localhost:31316/ HTTP/1.1";
            is @lines[1], "Host: localhost:31316";
        }
    }

    {
        my $c = Cro::HTTP::Client.new(base-uri => "http://localhost:{HTTP_TEST_PORT}", http-proxy => "http://localhost:{PROXY_TEST_PORT}");
        given await $c.get('/') -> $resp {
            my @lines = (await $resp.body).decode.lines[^2];
            is @lines[0], "GET http://localhost:31316/ HTTP/1.1";
            is @lines[1], "Host: localhost:31316";
        }
    }

    {
        my $c = Cro::HTTP::Client.new(base-uri => "https://localhost:{HTTP_TEST_PORT}", https-proxy => "http://localhost:{PROXY_TEST_PORT}");
        given await $c.get('/', :secure) -> $resp {
            my @lines = (await $resp.body).decode.lines[^2];
            is @lines[0], "GET https://localhost:31316/ HTTP/1.1";
            is @lines[1], "Host: localhost:31316";
        }
    }
}

{
    my $base = "http://localhost:{HTTP_TEST_PORT}";

    throws-like { await Cro::HTTP::Client.get("$base/random-page"); }, X::Cro::HTTP::Error::Client,
        'It throws exception for 405';

    throws-like { await Cro::HTTP::Client.get("$base/error"); }, X::Cro::HTTP::Error::Server,
        'It throws exception for 500';

    my $c = Cro::HTTP::Client.new(base-uri => "http://localhost:{HTTP_TEST_PORT}");
    given await $c.get('/') -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'base-uri argument works';
    }

    given await Cro::HTTP::Client.get("http://localhost:{HTTP_TEST_PORT}/") -> $resp {
        ok $resp.request.defined, 'Request object is associated with response';
        is $resp.request.uri, "$base/", 'The uri property of the request object is set';
    }

    given await Cro::HTTP::Client.get("$base/") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from GET /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Home', 'Body text is correct';
    }

    given await Cro::HTTP::Client.get-body("$base/") -> $resp {
        ok $resp ~~ Str, 'Got a string body back from GET /';
        is $resp, 'Home', 'Body has correct value';
    }

    given await Cro::HTTP::Client.post("$base/") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from POST /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Updated', 'Body text is correct';
    }

    given await Cro::HTTP::Client.post-body("$base/") -> $resp {
        ok $resp ~~ Str, 'Got a string body back from POST /';
        is $resp, 'Updated', 'Body has correct value';
    }

    given await Cro::HTTP::Client.put("$base/") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from PUT /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Saved', 'Body text is correct';
    }

    given await Cro::HTTP::Client.put-body("$base/") -> $resp {
        ok $resp ~~ Str, 'Got a string body back from PUT /';
        is $resp, 'Saved', 'Body has correct value';
    }

    given await Cro::HTTP::Client.delete("$base/") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from DELETE /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Gone', 'Body text is correct';
    }

    given await Cro::HTTP::Client.delete-body("$base/") -> $resp {
        ok $resp ~~ Str, 'Got a string body back from DELETE /';
        is $resp, 'Gone', 'Body has correct value';
    }

    given await Cro::HTTP::Client.patch("$base/") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from PATCH /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Patched', 'Body text is correct';
    }

    given await Cro::HTTP::Client.patch-body("$base/") -> $resp {
        ok $resp ~~ Str, 'Got a string body back from PATCH /';
        is $resp, 'Patched', 'Body has correct value';
    }

    given await Cro::HTTP::Client.get("$base/") -> $resp {
        is await($resp.body-blob).list, 'Home'.encode('ascii').list,
            'Can also get body back as a blob';
    }

    given await Cro::HTTP::Client.get("$base/query?value=test") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from GET /query?value=test';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'TEST', 'Body text is correct';
    }

    given await Cro::HTTP::Client.get("$base/query?value=تست") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Accepts an IRI';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'تست', 'Body text is correct';
    }

    given await Cro::HTTP::Client.get("$base/query") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from GET /query';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'No Query', 'Body text is correct';
    }

    my %body = reason => 'works';
    throws-like { await Cro::HTTP::Client.get("$base/",
                                              content-type => 'application/json',
                                              body => %body,
                                              body-byte-stream => supply {}); },
        X::Cro::HTTP::Client::BodyAlreadySet,
        'Body cannot be set twice';

    given await Cro::HTTP::Client.get("$base/json",
                                      content-type => 'application/json',
                                      body => %body) -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response from GET / with JSON';
        is await($resp.body-text), 'works', 'JSON was sent and processed';
    }

    given await Cro::HTTP::Client.get("$base/str",
            content-type => 'text/plain; charset=UTF-8',
            body => 'Plain string') -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response from GET / with Str';
        is await($resp.body-text), 'Plain string', 'Str was sent and processed';
    }

    given await Cro::HTTP::Client.post("$base/str",
            content-type => 'text/plain; charset=UTF-8',
            body => 'Plain string') -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response from GET / with Str';
        is await($resp.body-text), 'Plain string - 12', 'Str was sent and processed';
    }
    given await Cro::HTTP::Client.get("$base/blob",
                                      content-type => 'image/jpeg', # Just to process as blob
                                      body => Blob.new("String".encode)) -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response from GET / with Blob';
        ok await($resp.body-blob) eq Blob.new('gnirtS'.encode), 'Blob was sent and processed';
    }

    given await Cro::HTTP::Client.get("$base/urlencoded",
                                      content-type => 'application/x-www-form-urlencoded',
                                      body => [name => 'John',
                                               surname => 'Doe']) -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response from GET / with urlencoded query';
        is await($resp.body-text), "Welcome, John Doe!", 'Query params were sent and processed';
    }

    my $part = Cro::HTTP::Body::MultiPartFormData::Part.new(
        headers => [Cro::HTTP::Header.new(
                           name => 'Content-type',
                           value => 'image/jpeg'
                       )],
        name => 'photo',
        filename => 'secret.jpg',
        body-blob => Buf[uint8].new("It is a secret!".encode)
    );

    given await Cro::HTTP::Client.get("$base/multipart",
                                      content-type => 'multipart/form-data',
                                      body => [name => 'John',
                                               surname => 'Doe',
                                               $part]) -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response from GET / with form-data';
        is await($resp.body-text), "You are cute!", 'Form data was sent and processed';
    }

    given await Cro::HTTP::Client.get("$base/path",
                                      headers => [ User-agent => 'Cro' ]) -> $resp {
        is await($resp.body-text), 'When you are Cro, it is fine to request', 'Default headers were sent';
    }

    given await Cro::HTTP::Client.new.get("$base/path") -> $resp {
        is await($resp.body-text), 'When you are Cro, it is fine to request', 'User-Agent if set for Client instance';
    }

    given await Cro::HTTP::Client.get("$base/path") -> $resp {
        is await($resp.body-text), 'When you are Cro, it is fine to request', 'User-Agent if set if request invoked from Client type object';
    }

    given await Cro::HTTP::Client.new(user-agent => 'Cro/Cro').get("$base/path") -> $resp {
        is await($resp.body-text), 'When you are Cro/Cro, it is fine to request', 'User-agent value is passed from instance';
    }
    given await Cro::HTTP::Client.new(user-agent => 'Cro/Cro').get("$base/path", :user-agent('Cro/Cro/Cro')) -> $resp {
        is await($resp.body-text), 'When you are Cro/Cro/Cro, it is fine to request', 'User-agent value is passed from both instance and method with method one winning';
    }

    throws-like { await Cro::HTTP::Client.get("$base/path", user-agent => Nil); }, X::Cro::HTTP::Error::Client,
        'User-agent header is not added if explicitly set to Nil';

    throws-like { await Cro::HTTP::Client.get("$base/path", user-agent => ''); }, X::Cro::HTTP::Error::Client,
        'User-agent header is not added if explicitly set to empty string';

    throws-like { await Cro::HTTP::Client.get("$base/path", :!user-agent); }, X::Cro::HTTP::Error::Client,
        'User-agent header is not added if explicitly set to False';

    my $client = Cro::HTTP::Client.new(headers => [ User-agent => 'Good Cro' ]);
    given await $client.get("$base/path") -> $resp {
        is await($resp.body-text), 'When you are Good Cro, it is fine to request', 'Default headers were sent';
    }

    $client = Cro::HTTP::Client.new(headers => [ 1 ]);
    throws-like { $client.get("$base/path") }, X::Cro::HTTP::Client::IncorrectHeaderType,
        'Client header can only be Pair or Cro::HTTP::Header instance';

    lives-ok { $client = Cro::HTTP::Client.new(:cookie-jar); }, 'Bool flag for cookies';

    my $jar = Cro::HTTP::Client::CookieJar.new;
    lives-ok { $client = Cro::HTTP::Client.new(cookie-jar => $jar); }, 'Predefined jar of cookies';

    given await $client.get("$base/cookie-one") -> $resp {
        is await($resp.body-text), 'First is set', 'Browser-like cookie handling works 1';
    }
    given await $client.get("$base/cookie-one") -> $resp {
        is await($resp.body-text), 'First was sent', 'Browser-like cookie handling works 2';
    }

    given await $client.get("$base/cookie-two") -> $resp {
        is await($resp.body-text), 'Second is set', 'Browser-like cookie handling works 3';
    }
    given await $client.get("$base/cookie-two") -> $resp {
        is await($resp.body-text), 'Second was sent', 'Browser-like cookie handling works 4';
    }

    throws-like { await $client.get("$base/cookie-three") }, X::Cro::HTTP::Error::Client,
      'Cookies for routes 1 and 2 were not sent for 3';

    $client = Cro::HTTP::Client.new;
    given await $client.get("$base/cookie-three", :cookies(First => 'Done', Second => 'Done',)) -> $resp {
        is await($resp.body-text), 'Cookies are present', 'Cookies set externally work';
    }

    $client = Cro::HTTP::Client.new: content-type => 'text/plain';
    given await $client.get("$base/str", body => 'Traces') -> $resp {
        is await($resp.body), 'Traces', 'Permanent content-type setting works'
    };

    # Serialization
    $client = Cro::HTTP::Client.new: body-serializers => [];
    throws-like {
        await $client.get("$base/",
                          content-type => 'text/plain',
                          body => 'String');
    },
    X::Cro::BodySerializerSelector::NoneApplicable,
    'Request to server without serializers ends up with client error';

    $client = Cro::HTTP::Client.new: body-serializers => [Cro::HTTP::BodySerializer::JSON.new];

    given await $client.get("$base/json",
                            content-type => 'application/json',
                            body => %body) -> $resp {
        is await($resp.body-text), 'works', 'Response body is correct';
    }
    throws-like {
        await $client.get("$base/json", content-type => 'text/plain',
                          body => "Calling the Rain")
    },
    X::Cro::BodySerializerSelector::NoneApplicable,
    'Request with incorrect content-type is rejected';

    $client = Cro::HTTP::Client.new: body-serializers => [Cro::HTTP::BodySerializer::JSON.new],
                                     add-body-serializers => [Cro::HTTP::BodySerializer::StrFallback.new];

    given await $client.get("$base/json",
                            content-type => 'application/json',
                            body => %body) -> $resp {
        is await($resp.body-text), 'works', 'Request for main serializer works';
    };
    given await $client.get("$base/str", content-type => 'text/plain',
                            body => 'Calling the Rain') -> $resp {
        is await($resp.body-text), 'Calling the Rain', 'Request for additional serializer works';
    };

    # Parsing
    $client = Cro::HTTP::Client.new: body-parsers => [];

    given await $client.get("$base/str",
                            content-type => 'text/plain',
                            body => 'Funeral Dreams') -> $resp {
        throws-like { await($resp.body) },
        X::Cro::BodyParserSelector::NoneApplicable,
        'Attempt to get body without any parsers fails';
    };

    $client = Cro::HTTP::Client.new: body-parsers => [Cro::HTTP::BodyParser::TextFallback.new];

    given await $client.get("$base/json",
                            content-type => 'application/json',
                            body => %body) -> $resp {
        is await($resp.body), "works", 'Response body is correct'
    };

    given await $client.get("$base/get-json", content-type => 'text/plain',
                            body => "Calling the Rain") -> $resp {
        throws-like { await($resp.body) },
        X::Cro::BodyParserSelector::NoneApplicable,
        'Attempt to get body without any parsers fails';
    }

    $client = Cro::HTTP::Client.new: body-parsers => [Cro::HTTP::BodyParser::TextFallback.new],
                                     add-body-parsers => [Cro::HTTP::BodyParser::JSON.new];
    given await $client.get("$base/json",
                            content-type => 'application/json',
                            body => %body) -> $resp {
        is await($resp.body), "works", 'Main response parser works'
    };

    given await $client.get("$base/get-json", content-type => 'text/plain',
                            body => "Calling the Rain") -> $resp {
        is await($resp.body), {:42truth}, 'Additional response parser works'
    }

    given await $client.get-body("$base/get-json", content-type => 'text/plain',
            body => "Calling the Rain") -> $resp {
        is-deeply $resp, {:42truth}, 'get-body respects body parsers'
    }

    $client = Cro::HTTP::Client.new(:!follow);

    given await $client.get("$base/single-redirect") -> $resp {
        is $resp.status, 308, 'Get redirect response';
        ok $resp.request.defined, 'Request is set for redirected response';
    }

    $client = Cro::HTTP::Client.new;

    {
        try {
            await $client.get("$base/eternal-redirect");
        }
        CATCH {
            when X::Cro::HTTP::Client::TooManyRedirects {
                ok True, 'Client detects too many redirects';
                ok .response.request.defined, 'Request is set for eternal redirect exception';
                ok .request.defined, 'Request is accessible using X::Cro::HTTP::Client exception shortcut';
            }
            default {
                ok False, 'Got wrong exception type for eternal redirect';
            }
        }
    }

    given await $client.get("$base/single-redirect",
                            body => 'The Seed') -> $resp {
        is await($resp.body), 'The Seed', 'Single permanent redirect works';
        is $resp.request.uri, "$base/str",
            'The uri property of the request object is the followed uri';
    }

    given await $client.post("$base/get-303", body => 'Lines') -> $resp {
        is await($resp.body), 'Home', '303 redirect works'
    }

    given await $client.post("$base/post-307", body => 'Heights') -> $resp {
        is await($resp.body), 'Heights - 7', '307 redirect carries request body';
    }

    given await $client.post("$base/post-307-relative", body => 'Heights') -> $resp {
        is await($resp.body), 'Heights - 7', '307 relative redirect carries request body';
    }

    # Covers a bug where a redirect failed if the initial request had to / in the URI
    given await $client.get("http://localhost:{ROOT_REDIRECT_TEST_PORT}") -> $resp {
        is await($resp.body), 'ok', 'Redirect works when initial request URI has no path part';
    }

    throws-like { my $client = Cro::HTTP::Client.new(auth =>
                                                     {username => "User",
                                                      password => "Password",
                                                      bearer => "Token"}) },
    X::Cro::HTTP::Client::InvalidAuth,
    'Client cannot accept basic and bearer authentication simultaneously';

    $client = Cro::HTTP::Client.new(auth => {
                                           username => 'User',
                                           password => 'Password'});

    given await $client.get("$base/auth-echo") -> $resp {
        is await($resp.body), "Basic {encode-base64('User:Password', :str)}", 'Basic authentication header is set';
    }

    given await $client.get("$base/auth-echo", auth => {
                                   username => 'Jack',
                                   password => 'Password'}) -> $resp {
        is await($resp.body), "Basic {encode-base64('Jack:Password', :str)}", 'Basic authentication header can be overriden';
    }

    given await $client.get("$base/auth-echo", auth => {
                                   bearer => 'secret'}) -> $resp {
        is await($resp.body), "Bearer secret", 'Bearer authentication works';
    }

    given await $client.get("$base/auth-echo", auth => {
                                   bearer => 'secret',
                                   if-asked => True}) -> $resp {
        is await($resp.body), "Bearer secret", 'if-asked works properly';
    }

    given await($client.get("$base/query-string", query => { x => 42, y => 'foo' })) -> $resp {
        is await($resp.body), "x = 42, y = foo", 'query works properly with hash';
    }

    given await($client.get("$base/query-string", query => [x => 42, y => 'foo' ])) -> $resp {
        is await($resp.body), "x = 42, y = foo", 'query works properly with list of pairs';
    }

    given await($client.get("$base/query-string?x=42", query => [y => 'foo'])) -> $resp {
        is await($resp.body), "x = 42, y = foo", 'query adds to existing query string';
    }
}

{
    my $base = "http://localhost:{HTTP_TEST_PORT}";
    my $client = Cro::HTTP::Client.new;
    my $lock = Lock.new;
    my $p = Promise.new;
    my $counter = 0;
    for ^5 {
        start {
            my $resp = await $client.get("$base/");
            my $body = await $resp.body-text;
            $lock.protect({ $counter++ if $body eq 'Home'; $p.keep if $counter == 5; });
        }
    }
    await Promise.anyof($p, Promise.in(2));
    is $counter, 5, 'Concurrent client works';
}

if supports-alpn() {
    my $base = "https://localhost:{HTTPS_TEST_PORT}";

    given await Cro::HTTP::Client.get("$base/", :%ca) -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from GET / with HTTPS';
    }
} else {
    use Cro::TLS;
    skip 'No ALPN support', 1;
}

done-testing;
