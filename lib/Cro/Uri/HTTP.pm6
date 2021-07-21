use Cro::HTTP::MultiValue;
use Cro::ResourceIdentifier::HTTP;

package EXPORT::decode-query-string-part {
    our &decode-query-string-part = &Cro::ResourceIdentifier::HTTP::decode-query-string-part;
}

class Cro::Uri::HTTP is Cro::Uri does Cro::ResourceIdentifier::HTTP {
    grammar Parser is Cro::Uri::GenericParser {
        proto token request-target { * }
        token request-target:sym<origin-form> {
            <absolute-path> [ "?" <query> ]?
        }

        token absolute-path {
            [ "/" <segment> ]+
        }
    }

    grammar Actions is Cro::Uri::GenericActions {
        method request-target:sym<origin-form>($/) {
            make Cro::Uri::HTTP.bless(
                path => $<absolute-path>.ast,
                |(query => .ast with $<query>)
            );
        }

        method absolute-path($/) {
            make ~$/;
        }
    }

    method parse-request-target(Str() $target) {
        with Parser.parse($target, :actions(Actions), :rule('request-target')) {
            .ast
        }
        else {
            die X::Cro::Uri::ParseError.new(uri-string => $target)
        }
    }
}