use Cro::HTTP::Response;
use Test;

constant HTTP_TEST_PORT = 31316;
constant HTTPS_TEST_PORT = 31317;
constant %ca := { ca-file => 't/certs-and-keys/ca-crt.pem' };
constant %key-cert := {
    private-key-file => 't/certs-and-keys/server-key.pem',
    certificate-file => 't/certs-and-keys/server-crt.pem'
};

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
        get -> 'json' {
            request-body -> %json {
                content 'text/plain', "%json<reason>";
            }
        }
        get -> 'str' {
            request-body-text -> $str {
                content 'text/plain', "$str";
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
        ssl => %key-cert
    );
    $https-server.start();
    END $https-server.stop();
}

{
    use Cro::HTTP::Client;
    my $base = "http://localhost:{HTTP_TEST_PORT}";

    given await Cro::HTTP::Client.get("$base/") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from GET /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Home', 'Body text is correct';
    }

    given await Cro::HTTP::Client.post("$base/") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from POST /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Updated', 'Body text is correct';
    }

    given await Cro::HTTP::Client.put("$base/") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from PUT /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Saved', 'Body text is correct';
    }

    given await Cro::HTTP::Client.delete("$base/") -> $resp {
        ok $resp ~~ Cro::HTTP::Response, 'Got a response back from DELETE /';
        is $resp.status, 200, 'Status is 200';
        like $resp.header('Content-type'), /text\/plain/, 'Correct content type';
        is await($resp.body-text), 'Gone', 'Body text is correct';
    }

    given await Cro::HTTP::Client.get("$base/") -> $resp {
        is await($resp.body-blob).list, 'Home'.encode('ascii').list,
            'Can also get body back as a blob';
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

    my $client = Cro::HTTP::Client.new(headers => [ User-agent => 'Cro' ]);
    given await $client.get("$base/path") -> $resp {
        is await($resp.body-text), 'When you are Cro, it is fine to request', 'Default headers were sent';
    }

    $client = Cro::HTTP::Client.new(headers => [ 1 ]);
    throws-like { $client.get("$base/path") }, X::Cro::HTTP::Client::IncorrectHeaderType,
        'Client header can only be Pair or Cro::HTTP::Header instance';
}

done-testing;

