unit module Cro::HTTP::RouteSignatureToSub;
use Cro::Uri :encode-percents;

class RouteSignatureURLHolder {
    has Callable $.fn is required;
    has Str $.prefix;

    method CALL-ME(|c) { self.absolute(|c) }
    method relative(|c) { $!fn(|c) }
    method absolute(|c) { '/' ~ ($!prefix ?? $!prefix ~ '/' !! '') ~ $!fn(|c) }
    method url(|c) {
        my $root-url = $*CRO-ROOT-URL or die 'No CRO-ROOT-URL configured';
        $root-url ~ ($root-url.ends-with('/') ?? '' !! '/') ~ ($!prefix ?? "$!prefix/" !! '') ~ $!fn(|c)
    }
}

sub route-signature-to-sub(Str $prefix, Signature $s) is export {
    RouteSignatureURLHolder.new(:$prefix, fn => signature-to-sub($s))
}

sub signature-to-sub(Signature $s) {
    sub extract-static-part(Parameter $p) {
        if $p.constraint_list == 1 && $p.constraint_list[0] ~~ Str {
            return $p.constraint_list[0]
        }
    }

    my @path-parts;
    my @fn-parts;
    my $has-slurpy;
    my $has-slurpy-named;
    my %allowed-named;
    my %required-named;
    my @default;
    my $min-args = 0;
    for $s.params.kv -> $i, $param {
        if $param.positional {
            with extract-static-part $param -> $part {
                @path-parts[$i] = $part;
            } else {
                ++$min-args;
                @fn-parts.push: $i;
                if $param.optional {
                    @default.push: $_ with $param.default
                }
            }
        } elsif $param.named {
            if $param.slurpy {
                $has-slurpy-named = True;
                next;
            }

            %allowed-named{$param.usage-name} = True;
            unless $param.optional {
                %required-named{$param.usage-name} = True
            }
        } elsif $param.slurpy {
            $has-slurpy = True;
        }
        # otherwise it's a Capture, which the router doesn't allow
    }
    my $allowed-nameds = %allowed-named.keys.Set;
    my $required-nameds = %required-named.keys.Set;

    -> *@args, *%nameds {
        if @args < $min-args {
            die "Not enough arguments";
        }

        my @result = @path-parts;
        my @available-default = @default;
        for @fn-parts -> $i {
            if @args {
                @result[$i] = @args.shift
            } elsif @available-default {
                @result[$i] = @available-default.shift
            }
            # Otherwise, an optional wasn't filled, leave empty
        }

        if @args && !$has-slurpy {
            die "Extraneous arguments";
        }

        if !$has-slurpy-named {
            my $passed-nameds = %nameds.keys.Set;
            my $missing-nameds = $required-nameds (-) $passed-nameds;
            my $extra-nameds = $passed-nameds (-) $allowed-nameds;
            if $missing-nameds || $extra-nameds {
                my @parts = (
                    |("Missing named arguments: " ~ $missing-nameds.keys.sort.join(', ') if $missing-nameds),
                    |("Extraneous named arguments: " ~ $extra-nameds.keys.sort.join(', ') if $extra-nameds)
                );
                die @parts.join('. ') ~ '.';
            }
        }

        @result.append: @args;
        my $result = @result.join: '/';
        if %nameds {
            $result ~= '?' ~ %nameds.sort(*.key).map({ encode-percents(.key) ~ "=" ~ encode-percents(.value.Str) }).join('&');
        }
        $result
    }
}
