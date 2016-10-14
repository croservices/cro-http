use Crow::HTTP::RequestParser;
use Crow::HTTP::Request;
use Crow::TCP;
use Test;

ok Crow::HTTP::RequestParser ~~ Crow::Processor,
    'HTTP request parser is a processor';
ok Crow::HTTP::RequestParser.consumes === Crow::TCP::Message,
    'HTTP request parser consumes TCP messages';
ok Crow::HTTP::RequestParser.produces === Crow::HTTP::Request,
    'HTTP request parser produces HTTP requests';

done-testing;
