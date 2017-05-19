use Cro::Transform;
use Cro::TCP;
use Cro::HTTP::RawBodyParserSelector;
use Cro::HTTP::Response;
use Cro::Workarounds;

class Cro::HTTP::ResponseParser does Cro::Transform {
    has Cro::HTTP::RawBodyParserSelector $.raw-body-parser-selector =
        Cro::HTTP::RawBodyParserSelector::Default;

    method consumes() { Cro::TCP::Message }
    method produces() { Cro::HTTP::Response }

    method transformer(Supply:D $in) {
        supply {
            my enum Expecting <StatusLine Header Body>;
            my $expecting = StatusLine;

            my $header-decoder = StreamingDecoder.new('iso-8859-1');
            $header-decoder.set-line-separators(["\r\n", "\n"]); # XXX Hack; toss \n

            my $response = Cro::HTTP::Response.new;
            my $body-stream;

            whenever $in -> Cro::TCP::Message $packet {
                $header-decoder.add-bytes($packet.data);
                loop {
                    $_ = $expecting;
                    when StatusLine {
                        # Try to read the status line and parse it.
                        my $status-line = $header-decoder.consume-line-chars(:chomp);
                        last unless defined $status-line;
                        my $parsed = $status-line.match(
                            /^ 'HTTP/'(\d'.'\d) ' ' (\d\d\d) ' ' <[\t\ \x21..\xFF]>*$/);
                        die "Malformed status line" unless $parsed;

                        # Validate version.
                        my $version = $parsed[0].Str;
                        unless $version.starts-with('1') {
                            die "Unsupported HTTP version $version";
                        }

                        # Populate response.
                        $response.http-version = $version;
                        $response.status = $parsed[1].Int;

                        $expecting = Header;
                        proceed;
                    }
                    when Header {
                        # Try to read a header line
                        my $header-line = $header-decoder.consume-line-chars(:chomp);
                        last unless defined $header-line;

                        # If it's a blank line, then we've a response, and
                        # the rest will be the body. Otherwise, parse header.
                        if $header-line eq '' {
                            my $raw-body-parser = $!raw-body-parser-selector.select($response);
                            $body-stream = Supplier::Preserving.new;
                            $response.set-body($raw-body-parser.parser($response,
                                $body-stream.Supply));
                            $body-stream.emit($header-decoder.consume-all-bytes());
                            emit $response;
                            $expecting = Body;
                            last;
                        }
                        else {
                            my $header = Cro::HTTP::Header.parse($header-line);
                            $response.append-header($header);
                        }
                    }
                    when Body {
                        $body-stream.emit($packet.data);
                        last;
                    }
                }
                LAST {
                    $body-stream.?done;
                }
            }
        }
    }
}
