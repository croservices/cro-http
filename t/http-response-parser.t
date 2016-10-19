use Crow::HTTP::ResponseParser;
use Crow::HTTP::Response;
use Crow::TCP;
use Test;

ok Crow::HTTP::ResponseParser ~~ Crow::Processor,
    'HTTP response parser is a processor';
ok Crow::HTTP::ResponseParser.consumes === Crow::TCP::Message,
    'HTTP response parser consumes TCP messages';
ok Crow::HTTP::ResponseParser.produces === Crow::HTTP::Response,
    'HTTP respose parser produces HTTP responses';
