use Cro::HTTP::Message;

role Cro::HTTP::RawBodyParser {
    method parser(Cro::HTTP::Message $message, Supply $raw-blobs,
                  Promise $leftover? --> Supply) { ... }
}

class Cro::HTTP::RawBodyParser::UntilClosed does Cro::HTTP::RawBodyParser {
    method parser(Cro::HTTP::Message $message, Supply $raw-blobs,
                  Promise $leftover? --> Supply) {
        supply {
            whenever $raw-blobs {
                .emit;
            }
        }
    }
}

class X::Cro::HTTP::RawBodyParser::ContentLength::TooShort is Exception {
    method message() { "Connection unexpectedly closed before body received" }
}

class Cro::HTTP::RawBodyParser::ContentLength does Cro::HTTP::RawBodyParser {
    method parser(Cro::HTTP::Message $message, Supply $raw-blobs,
                  Promise $leftover? --> Supply) {
        supply {
            my int $expected = $message.header('content-length').Int;
            whenever $raw-blobs -> $blob {
                if $blob.elems > $expected {
                    emit $blob.subbuf(0, $expected); # we get message
                    .keep($blob.subbuf($expected)) with $leftover; # and something else
                    done;
                } else {
                    emit $blob;
                    $expected -= $blob.elems;
                    if $expected == 0 {
                        .keep(Blob.allocate(0)) with $leftover;
                        done; # We get all message
                    }
                }

                LAST {
                    if $expected != 0 {
                        die X::Cro::HTTP::RawBodyParser::ContentLength::TooShort.new;
                    }
                }
            }
        }
    }
}

class Cro::HTTP::RawBodyParser::Chunked does Cro::HTTP::RawBodyParser {
    my enum State <AwaitingLength AwaitingChunkEnd>;

    method parser(Cro::HTTP::Message $message, Supply $raw-blobs,
                  Promise $leftover? --> Supply) {
        supply {
            my $state = AwaitingLength;
            my $buffer = Buf.new;
            my Int $length-awaited = 0;

            whenever $raw-blobs -> $blob {
                $buffer.append($blob);
                parse-chunks();
            }

            sub parse-chunks() {
                loop {
                    if $state == AwaitingLength {
                        loop (my int $i = 0; $i < $buffer.elems - 1; $i++) {
                            if $buffer[$i] == ord("\r") && $buffer[$i + 1] == ord("\n") {
                                my $length-buf = $buffer.subbuf(0, $i);
                                $length-awaited = :16($length-buf.decode('ascii'));
                                $buffer .= subbuf($i + 2);
                                $state = AwaitingChunkEnd;
                                last;
                            }
                        }
                        if $state == AwaitingLength {
                            # Need more data to have a length
                            last;
                        }
                        elsif $length-awaited == 0 {
                            # Zero marks the last chunk.
                            done;
                        }
                    }
                    else {
                        if $buffer.elems >= $length-awaited + 2 {
                            die "Malformed chunk ending"
                                unless $buffer[$length-awaited] == ord("\r") &&
                                       $buffer[$length-awaited + 1] == ord("\n");
                            emit $buffer.subbuf(0, $length-awaited);
                            $buffer .= subbuf($length-awaited + 2);
                            $state = AwaitingLength;
                        }
                        else {
                            # Missing data to complete chunk.
                            last;
                        }
                    }
                }
            }
        }
    }
}
