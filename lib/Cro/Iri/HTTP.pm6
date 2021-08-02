use Cro::Uri :decode-percents, :encode-percents;
use Cro::HTTP::MultiValue;
use Cro::Uri::HTTP;
use Cro::Iri;
use Cro::ResourceIdentifier::HTTP;

class Cro::Iri::HTTP is Cro::Iri does Cro::ResourceIdentifier::HTTP {
    grammar Parser is Cro::Iri::GenericParser {
        proto token request-target { * }
        token request-target:sym<origin-form> {
            <iabsolute-path> [ "?" <iquery> ]?
        }

        token iabsolute-path {
            [ "/" <isegment> ]+
        }
    }

    grammar Actions is Cro::Iri::GenericActions {
        method request-target:sym<origin-form>($/) {
            make Cro::Iri::HTTP.bless(
                path => $<iabsolute-path>.ast,
                |(query => .ast with $<iquery>)
            );
        }

        method iabsolute-path($/) {
            make ~$/;
        }
    }

    method parse-request-target(Str() $target) {
        with Parser.parse($target, :actions(Actions), :rule('request-target')) {
            .ast
        }
        else {
            die X::Cro::Iri::ParseError.new(iri-string => $target)
        }
    }

    method to-uri-http(--> Cro::Uri::HTTP) {
        Cro::Uri::HTTP.new(:$.path, :$.query)
    }
}
