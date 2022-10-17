class Cro::HTTP2::ConnectionState {
    class WindowAdd {
        has $.stream-identifier;
        has $.increment;
    }
    class WindowConsume {
        has $.stream-identifier;
        has $.bytes;
        has $.promise;
    }
    class WindowInitial {
        has $.initial;
    }
    has Supplier $.settings = Supplier.new;
    has Supplier $.ping = Supplier.new;
    has Supplier $.window-size = Supplier.new;
    has $!initial-window-size = 65535;
    has Supplier $.remote-window-change = Supplier.new;
    # Connection represented as stream 0.
    has @!remote-window-sizes;
    has @!remote-window-consume-queue;
    has Supplier $.push-promise = Supplier.new;
    has Supplier $.stream-reset = Supplier.new;

    submethod TWEAK() {
        sub check-window-size($wc) {
            if $wc.bytes <= @!remote-window-sizes[0] &&
                    $wc.bytes <= @!remote-window-sizes[$wc.stream-identifier] {
                @!remote-window-sizes[0] -= $wc.bytes;
                @!remote-window-sizes[$wc.stream-identifier] -= $wc.bytes;
                $wc.promise.keep;
                return True;
            }
            return False;
        }
        @!remote-window-sizes[0] = $!initial-window-size;

        $!remote-window-change.Supply.tap: {
            when WindowAdd {
                @!remote-window-sizes[.stream-identifier] = $!initial-window-size without @!remote-window-sizes[.stream-identifier];
                @!remote-window-sizes[.stream-identifier] += .increment;
                while @!remote-window-consume-queue && check-window-size(@!remote-window-consume-queue[*-1]) {
                    @!remote-window-consume-queue.pop;
                }
            }
            when WindowConsume {
                # For some reason I do not understand Rakudo throws the following error when I inline the
                # `.stream-identifier`, even more obscure as it works flawlessly above:
                # "No such method 'stream-identifier' for invocant of type 'Any'"
                my $stream = .stream-identifier;
                @!remote-window-sizes[$stream] = $!initial-window-size without @!remote-window-sizes[$stream];
                unless check-window-size($_) {
                    @!remote-window-consume-queue.push($_)
                }
            }
            when WindowInitial {
                @!remote-window-sizes »+=» .initial - $!initial-window-size;
                $!initial-window-size = .initial;
            }
        };
    }
}
