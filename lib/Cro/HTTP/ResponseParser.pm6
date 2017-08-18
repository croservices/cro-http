use Cro::Transform;
use Cro::TCP;
use Cro::HTTP::RawBodyParserSelector;
use Cro::HTTP::Response;

class Cro::HTTP::ResponseParser does Cro::Transform {
    has Cro::HTTP::RawBodyParserSelector $.raw-body-parser-selector =
        Cro::HTTP::RawBodyParserSelector::Default;

    method consumes() { Cro::TCP::Message }
    method produces() { Cro::HTTP::Response }

    sub preserve(Supply:D $s) {
        my $p = Supplier::Preserving.new;
        $s.tap: { $p.emit($_) }, done => -> { $p.done }, quit => { $p.quit($_) };
        $p.Supply
    }

    method transformer(Supply:D $in) {
        supply {
            my enum Expecting <StatusLine Header Body>;

            my $header-decoder = Encoding::Registry.find('iso-8859-1').decoder();
            $header-decoder.set-line-separators(["\r\n", "\n"]); # XXX Hack; toss \n

            my $expecting;
            my $response;
            my $raw-body-byte-stream;
            my $leftover;

            my sub fresh-message() {
                $expecting = StatusLine;
                $response = Cro::HTTP::Response.new;
                $header-decoder.add-bytes($leftover.result) with $leftover;
                $leftover = Promise.new;
            }
            fresh-message;

            whenever $in -> Cro::TCP::Message $packet {
                $header-decoder.add-bytes($packet.data) unless $expecting == Body;
                loop {
                    $_ = $expecting;
                    when StatusLine {
                        # Try to read the status line and parse it.
                        my $status-line = $header-decoder.consume-line-chars(:chomp);
                        last unless defined $status-line;
                        next if $status-line eq '';
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
                            $raw-body-byte-stream = Supplier.new;
                            $response.set-body-byte-stream(preserve(
                                $raw-body-parser.parser($response,
                                    $raw-body-byte-stream.Supply, $leftover)));
                            my int $count = $header-decoder.bytes-available();
                            $raw-body-byte-stream.emit($header-decoder.consume-exactly-bytes($count));
                            emit $response;
                            if $leftover.status == Kept {
                                fresh-message;
                                next;
                            }
                            else {
                                $expecting = Body;
                                last;
                            }
                        }
                        else {
                            my $header = Cro::HTTP::Header.parse($header-line);
                            $response.append-header($header);
                        }
                    }
                    when Body {
                        $raw-body-byte-stream.emit($packet.data);
                        if $leftover.status == Kept {
                            my $nothing-left = $leftover.result eq Blob.allocate(0);
                            fresh-message;
                            $nothing-left ?? last() !! next();
                        }
                        else {
                            last;
                        }
                    }
                }
                LAST {
                    $raw-body-byte-stream.?done;
                }
            }
        }
    }
}
