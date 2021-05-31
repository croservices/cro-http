class Cro::HTTP::Header {
    has Str $.name;
    has Str $.value;

    my grammar Header {
        token TOP {
            || <field-name> ":" <.OWS> <field-value> <.OWS> $
            || { die "Malformed header '$/.orig()'" }
        }
        token field-name {
            <.token> { make ~$/ }
        }
        token field-value {
            # Deliberately omitted obs-fold, per RFC 7230 3.2.4.
            <.field-content> { make ~$/ }
        }
        token field-content {
            [<[\x21..\xFF]>+ [<[\t\ ]>+ <[\x21..\xFF]>+]*]?
        }
        token token {
            <[A..Z a..z 0..9 ! # $ % & ' * + . ^ _ ` | ~ -]>+
        }
        token OWS {
            <[\ \t]>*
        }
    }

    # Lookup table of common header names, since it's cheaper to do a lookup in a
    # hash table than to do the full parse.
    my constant %OK-HEADERS = :accept, :authorization, :cache-control, :connection,
                              :content-length, :content-type, :cookie, :date, :host,
                              :location, :referer, :set-cookie, :server, :upgrade;

    proto method new(|) {*}

    multi method new(Str :$name!, Str() :$value!) {
        die "Malformed header name '$name'"
            unless %OK-HEADERS{$name.lc} || Header.parse($name, :rule<token>);
        die "Malformed header value '$value'"
            unless Header.parse($value, :rule<field-content>);
        self.bless(:$name, :$value)
    }

    multi method new(Str :$name, Int :$value) {
        die "Malformed header name '$name'"
            unless %OK-HEADERS{$name.lc} || Header.parse($name, :rule<token>);
        # We know the stringification of the integer value will be valid
        self.bless(:$name, :value($value.Str))
    }

    method parse(Cro::HTTP::Header:U: Str $header-line) {
        given Header.parse($header-line) {
            return Cro::HTTP::Header.bless(
                name => .<field-name>.ast,
                value => .<field-value>.ast
            );
        }
    }
}
