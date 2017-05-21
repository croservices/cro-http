use Cro::HTTP::BodyParserSelector;
use Cro::HTTP::BodySerializerSelector;
use Cro::HTTP::Message;

my constant %reason-phrases = {
    100 => "Continue",
    101 => "Switching Protocols",
    200 => "OK",
    201 => "Created",
    202 => "Accepted",
    203 => "Non-Authoritative Information",
    204 => "No Content",
    205 => "Reset Content",
    206 => "Partial Content",
    300 => "Multiple Choices",
    301 => "Moved Permanently",
    302 => "Found",
    303 => "See Other",
    304 => "Not Modified",
    305 => "Use Proxy",
    307 => "Temporary Redirect",
    400 => "Bad Request",
    401 => "Unauthorized",
    402 => "Payment Required",
    403 => "Forbidden",
    404 => "Not Found",
    405 => "Method Not Allowed",
    406 => "Not Acceptable",
    407 => "Proxy Authentication Required",
    408 => "Request Time-out",
    409 => "Conflict",
    410 => "Gone",
    411 => "Length Required",
    412 => "Precondition Failed",
    413 => "Request Entity Too Large",
    414 => "Request-URI Too Large",
    415 => "Unsupported Media Type",
    416 => "Requested range not satisfiable",
    417 => "Expectation Failed",
    418 => "I'm a teapot",
    500 => "Internal Server Error",
    501 => "Not Implemented",
    502 => "Bad Gateway",
    503 => "Service Unavailable",
    504 => "Gateway Time-out",
    505 => "HTTP Version not supported"
};

class Cro::HTTP::Response does Cro::HTTP::Message {
    subset StatusCode of Int where { 100 <= $_ <= 999 }
    has StatusCode $.status is rw;
    has Cro::HTTP::BodyParserSelector $.body-parser-selector is rw =
        Cro::HTTP::BodyParserSelector::ResponseDefault;
    has Cro::HTTP::BodySerializerSelector $.body-serializer-selector is rw =
        Cro::HTTP::BodySerializerSelector::ResponseDefault;

    multi method Str(Cro::HTTP::Response:D:) {
        my $status = $!status // (self!body-set ?? 200 !! 204);
        my $reason = %reason-phrases{$status} // 'Unknown';
        my $headers = self!headers-str();
        "HTTP/{self.http-version // '1.1'} $status $reason\r\n$headers\r\n"
    }
}
