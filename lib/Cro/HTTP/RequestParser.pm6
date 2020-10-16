use Cro::TCP;
use Cro::HTTP::Exception;
use Cro::HTTP::RawBodyParserSelector;
use Cro::HTTP::Request;
use Cro::HTTP::LogTimelineSchema;

class Cro::HTTP::RequestParser does Cro::Transform {
    has %!allowed-methods;
    has Cro::HTTP::RawBodyParserSelector $.raw-body-parser-selector =
        Cro::HTTP::RawBodyParserSelector::Default;

    submethod TWEAK(
        :@allowed-methods = <GET HEAD POST PUT DELETE PATCH CONNECT OPTIONS>
    ) {
        %!allowed-methods{@allowed-methods} = True xx *;
    }

    method allowed-methods() {
        %!allowed-methods.keys
    }

    method consumes() { Cro::TCP::Message }
    method produces() { Cro::HTTP::Request }

    sub preserve(Supply:D $s) {
        my $p = Supplier::Preserving.new;
        $s.tap: { $p.emit($_) }, done => -> { $p.done }, quit => { $p.quit($_) };
        $p.Supply
    }

    method transformer(Supply:D $in) {
        supply {
            my enum Expecting <RequestLine Header Body>;

            my $header-decoder = Encoding::Registry.find('iso-8859-1').decoder();
            $header-decoder.set-line-separators(["\r\n", "\n"]); # XXX Hack; toss \n

            my $expecting;
            my $request;
            my $raw-body-byte-stream;
            my $leftover;

            my sub fresh-message() {
                $expecting = RequestLine;
                $request = Cro::HTTP::Request.new;
                $header-decoder.add-bytes($leftover.result) with $leftover;
                $leftover = Nil;
            }
            fresh-message;

            whenever $in -> Cro::TCP::Message $packet {
                $header-decoder.add-bytes($packet.data) unless $expecting == Body;
                loop {
                    $_ = $expecting;
                    when RequestLine {
                        # Try to read the request line.
                        my $req-line = $header-decoder.consume-line-chars(:chomp);
                        last unless defined $req-line;

                        # Per rfc7230 3.5, empty lines before the header are
                        # acceptable.
                        next if $req-line eq '';

                        # Per rfc7230 3.1.1, we may in the case of a malformed
                        # header due to spaces in the target, we may issue a
                        # redirect. Should not try to fix it "in stream". For
                        # now, simply reject it.
                        my @parts = $req-line.split(' ');
                        bad-request('Malformed request line') unless @parts == 3;

                        # Validate.
                        not-implemented('Unsupported method ' ~ @parts[0])
                            unless %!allowed-methods{@parts[0]}:exists;
                        if @parts[2].match(/^'HTTP/'(\d)'.'(\d)$/) -> $ver {
                            unless $ver[0] eq '1' {
                                not-implemented('Unsupported HTTP version ' ~ ~$ver);
                            }
                        }
                        else {
                            bad-request('Malformed HTTP version');
                        }

                        # Populate the request object.
                        $request.connection = $packet.connection;
                        $request.method = @parts[0];
                        $request.target = @parts[1];
                        $request.http-version = @parts[2].substr(5);
                        $request.annotations<log-timeline> = Cro::HTTP::LogTimeline::Serve.start:
                                :method($request.method), :target($request.target);

                        $expecting = Header;
                    }
                    when Header {
                        # Try to read a header line
                        my $header-line = $header-decoder.consume-line-chars(:chomp);
                        last unless defined $header-line;

                        # If it's a blank line, then we've a request, and
                        # the rest will be the body. Otherwise, parse header.
                        if $header-line eq '' {
                            if $request.has-header('content-length')
                            || $request.has-header('transfer-encoding')
                            || $request.has-header('upgrade') {
                                my $raw-body-parser = $!raw-body-parser-selector.select($request);
                                $raw-body-byte-stream = Supplier.new;
                                $leftover = Promise.new;
                                $request.set-body-byte-stream(preserve(
                                    $raw-body-parser.parser($request,
                                        $raw-body-byte-stream.Supply, $leftover)));
                                my int $count = $header-decoder.bytes-available();
                                $raw-body-byte-stream.emit($header-decoder.consume-exactly-bytes($count));
                                emit $request;
                                if $leftover.status == Kept {
                                    fresh-message;
                                    next;
                                }
                                else {
                                    $expecting = Body;
                                    last;
                                }
                            } else {
                                emit $request;
                                fresh-message;
                            }
                        }
                        else {
                            my $header = Cro::HTTP::Header.parse($header-line);
                            $request.append-header($header);
                            CATCH {
                                default {
                                    bad-request('Malformed header');
                                }
                            }
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
                QUIT {
                    $raw-body-byte-stream.?done;
                }
            }
        }
    }

    sub bad-request($message) {
        die Cro::HTTP::Exception.new(:400status, :$message);
    }
    sub not-implemented($message) {
        die Cro::HTTP::Exception.new(:501status, :$message);
    }
}
