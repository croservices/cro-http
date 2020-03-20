use v6;

use Test;

use Cro::HTTP::RawBodyParserSelector;
use Cro::HTTP::RawBodyParser;

use Cro::HTTP::Response;


my @tests = (
                {
                    message => make-response(),
                    parser  => Cro::HTTP::RawBodyParser::UntilClosed,
                    description =>  "No content-length or transfer-encoding",
                },
                {
                    message => make-response(headers => { content-length => 10 }),
                    parser  => Cro::HTTP::RawBodyParser::ContentLength,
                    description => "Content-Length",
                },
                {
                    message => make-response(headers => { transfer-encoding => "chunked" }),
                    parser  => Cro::HTTP::RawBodyParser::Chunked,
                    description => "Chunked transfer encoding",
                },
                {
                    message => make-response(headers => { transfer-encoding => "identity" }),
                    parser  => Cro::HTTP::RawBodyParser::UntilClosed,
                    description => "Identity transfer encoding - no content-length",
                },
                {
                    message => make-response(headers => { transfer-encoding => "identity", content-length => 10 }),
                    parser  => Cro::HTTP::RawBodyParser::ContentLength,
                    description => "Identity transfer encoding - with content-length",
                },
            );

for @tests -> $test {
    lives-ok {
        ok Cro::HTTP::RawBodyParserSelector::Default.select($test<message>) ~~ $test<parser>, "got the correct 'Cro::HTTP::RawBodyParser'";
    }, $test<description>;
}

sub make-response(:%headers --> Cro::HTTP::Response) {
    my $resp = Cro::HTTP::Response.new;

    for %headers.kv -> $k, $v {
        $resp.append-header($k, $v);
    }
    $resp;
}

done-testing();

# vim: ft=perl6
