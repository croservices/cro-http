use Cro;
use Cro::HTTP::BodyParser;
use Cro::HTTP::BodyParserSelector;
use Cro::HTTP::Request;
use Cro::HTTP::Response;

class X::Cro::HTTP::Router::OnlyInHandler is Exception {
    has $.what;
    method message() {
        "Can only use '$!what' inside of a request handler"
    }
}
class X::Cro::HTTP::Router::NoRequestBodyMatch is Exception {
    method message() {
        "None of the request-body matches could handle the body (this exception " ~
        "type is typically caught and handled by Cro to produce a 400 Bad Request " ~
        "error; if you're seeing it, you may have an over-general error handling)"
    }
}

module Cro::HTTP::Router {
    role Query {}
    multi trait_mod:<is>(Parameter:D $param, :$query! --> Nil) is export {
        $param does Query;
    }
    role Header {}
    multi trait_mod:<is>(Parameter:D $param, :$header! --> Nil) is export {
        $param does Header;
    }

    class RouteSet does Cro::Transform {
        my class Handler {
            has Str $.method;
            has &.implementation;
        }

        has Handler @!handlers;
        has $!path-matcher;
        has Cro::HTTP::BodyParser @!body-parsers;

        method consumes() { Cro::HTTP::Request }
        method produces() { Cro::HTTP::Response }

        method transformer(Supply:D $requests) {
            supply {
                whenever $requests -> $req {
                    my $*CRO-ROUTER-REQUEST = $req;
                    my $*WRONG-METHOD = False;
                    my $*MISSING-UNPACK = False;
                    my @*BIND-FAILS;
                    with $req.path ~~ $!path-matcher {
                        if @!body-parsers {
                            $req.body-parser-selector = Cro::HTTP::BodyParserSelector::Prepend.new(
                                parsers => @!body-parsers,
                                next => $req.body-parser-selector
                            );
                        }
                        my $*CRO-ROUTER-RESPONSE := Cro::HTTP::Response.new();
                        my ($handler-idx, $arg-capture) = .ast;
                        my $handler := @!handlers[$handler-idx];
                        my &implementation := $handler.implementation;
                        if $req.path eq '/' { # XXX Should be able to avoid this
                            implementation();
                        }
                        else {
                            implementation(|$arg-capture);
                        }
                        emit $*CRO-ROUTER-RESPONSE;
                        CATCH {
                            when X::Cro::HTTP::Router::NoRequestBodyMatch {
                                $*CRO-ROUTER-RESPONSE.status = 400;
                                emit $*CRO-ROUTER-RESPONSE;
                            }
                        }
                    }
                    else {
                        my $status = 404;
                        if $*WRONG-METHOD {
                            $status = 405;
                        }
                        elsif $*MISSING-UNPACK {
                            $status = 400;
                        }
                        elsif @*BIND-FAILS {
                            for @*BIND-FAILS -> $imp, \cap {
                                $imp(|cap);
                                CATCH {
                                    when X::TypeCheck::Binding::Parameter {
                                        if .parameter.named {
                                            $status = 400;
                                            last;
                                        }
                                    }
                                    default {}
                                }
                            }
                        }
                        emit Cro::HTTP::Response.new(:$status);
                    }
                }
            }
        }

        method add-handler(Str $method, &implementation --> Nil) {
            @!handlers.push(Handler.new(:$method, :&implementation));
        }

        method add-body-parser(Cro::HTTP::BodyParser $parser --> Nil) {
            @!body-parsers.push($parser);
        }

        method definition-complete(--> Nil) {
            my @route-matchers;

            my @handlers = @!handlers; # This is closed over in the EVAL'd regex
            for @handlers.kv -> $index, $handler {
                # Things we need to do to prepare segments for binding and unpack
                # request data.
                my @make-tasks;

                # If we need a signature bind test (due to subset/where).
                my $need-sig-bind = False;

                # Positionals are URL segments, nameds are unpacks of other
                # request data.
                my $signature = $handler.implementation.signature;
                my (:@positional, :@named) := $signature.params.classify:
                    { .named ?? 'named' !! 'positional' };

                # Compile segments definition into a matcher.
                my @segments-required;
                my @segments-optional;
                my $segments-terminal = '';
                for @positional.kv -> $seg-index, $param {
                    if $param.slurpy {
                        $segments-terminal = '{} .*:';
                    }
                    else {
                        my @matcher-target := $param.optional
                            ?? @segments-optional
                            !! @segments-required;
                        my $type := $param.type;
                        my @constraints = extract-constraints($param);
                        if $type =:= Mu || $type =:= Any || $type =:= Str {
                            if @constraints == 1 && @constraints[0] ~~ Str:D {
                                # Literal string constraint; matches literally.
                                @matcher-target.push("'@constraints[0]'");
                            }
                            else {
                                # Any match will do, but need bind check.
                                @matcher-target.push('<-[/]>+:');
                                $need-sig-bind = True;
                            }
                        }
                        elsif $type =:= Int {
                            @matcher-target.push(Q['-'?\d+:]);
                            @make-tasks.push: Q:c/.=Int with @segs[{$seg-index}]/;
                            $need-sig-bind = True if @constraints;
                        }
                        else {
                            die "Parameter type $type.^name() not allowed as a URL segment matcher";
                        }
                    }
                }
                my $segment-matcher = " '/' " ~
                    @segments-required.join(" '/' ") ~
                    @segments-optional.map({ "[ '/' $_ " }).join ~ (' ]? ' x @segments-optional) ~
                    $segments-terminal;

                # Turned nameds into unpacks.
                my @checks;
                for @named -> $param {
                    my $target-name = $param.named_names[0];
                    my ($exists, $lookup) = do given $param {
                        when Query {
                            '$req.query-hash{Q[' ~ $target-name ~ ']}:exists',
                            '$req.query-value(Q[' ~ $target-name ~ '])'
                        }
                        when Header {
                            '$req.has-header(Q[' ~ $target-name ~ '])',
                            '$req.header(Q[' ~ $target-name ~ '])'
                        }
                        default {
                            die "Unhandled named parameter case";
                        }
                    }
                    unless $param.optional {
                        push @checks, '(' ~ $exists ~ ' || !($*MISSING-UNPACK = True))';
                    }

                    my $type := $param.type;
                    if $type =:= Mu || $type =:= Any || $type =:= Str {
                        push @make-tasks, '%unpacks{Q[' ~ $target-name ~ ']} = $_ with ' ~ $lookup;
                    }
                    elsif $type =:= Int {
                        push @checks, '(with ' ~ $lookup ~ ' { so /^"-"?\d+$/ } else { True })';
                        push @make-tasks, '%unpacks{Q[' ~ $target-name ~ ']} = .Int with ' ~ $lookup;
                    }
                    else {
                        die "Parameter type $type.^name() not allowed on a request unpack parameter";
                    }
                    $need-sig-bind = True if extract-constraints($param);
                }

                my $method-check = '<?{ $req.method eq "' ~ $handler.method ~
                    '" || !($*WRONG-METHOD = True) }>';
                my $checks = @checks
                    ?? '<?{ ' ~ @checks.join(' and ') ~ ' }>'
                    !! '';
                my $form-cap = '{ my %unpacks; ' ~ @make-tasks.join(';') ~
                    '; $cap = Capture.new(:list(@segs), :hash(%unpacks)); }';
                my $bind-check = $need-sig-bind
                    ?? '<?{ my $imp = @handlers[' ~ $index ~ '].implementation; ' ~
                            '$imp.signature.ACCEPTS($cap) || ' ~
                            '!(@*BIND-FAILS.push($imp, $cap)) }>'
                    !! '';
                my $make = '{ make (' ~ $index ~ ', $cap) }';
                push @route-matchers, join " ",
                    $segment-matcher, $method-check, $checks, $form-cap,
                    $bind-check, $make;
            }

            use MONKEY-SEE-NO-EVAL;
            push @route-matchers, '<!>';
            $!path-matcher = EVAL 'regex { ^ ' ~
                ':my $req = $*CRO-ROUTER-REQUEST; ' ~
                ':my @segs = $req.path-segments; ' ~
                ':my $cap; ' ~
                '[ '  ~ @route-matchers.join(' | ') ~ ' ] ' ~
                '$ }';
        }
    }

    sub extract-constraints(Parameter:D $param) {
        my @constraints;
        sub extract($v --> Nil) { @constraints.push($v) }
        extract($param.constraints);
        return @constraints;
    }

    sub route(&route-definition) is export {
        my $*CRO-ROUTE-SET = RouteSet.new;
        route-definition();
        $*CRO-ROUTE-SET.definition-complete();
        return $*CRO-ROUTE-SET;
    }

    sub get(&handler --> Nil) is export {
        $*CRO-ROUTE-SET.add-handler('GET', &handler);
    }

    sub post(&handler --> Nil) is export {
        $*CRO-ROUTE-SET.add-handler('POST', &handler);
    }

    sub put(&handler --> Nil) is export {
        $*CRO-ROUTE-SET.add-handler('PUT', &handler);
    }

    sub delete(&handler --> Nil) is export {
        $*CRO-ROUTE-SET.add-handler('DELETE', &handler);
    }

    sub body-parser(Cro::HTTP::BodyParser $parser --> Nil) is export {
        $*CRO-ROUTE-SET.add-body-parser($parser);
    }

    sub term:<request>() is export {
        $*CRO-ROUTER-REQUEST //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<request>)
    }

    sub term:<response>() is export {
        $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<response>)
    }

    sub request-body-blob(**@handlers) is export {
        run-body-handler(@handlers, await request.body-blob)
    }

    sub request-body-text(**@handlers) is export {
        run-body-handler(@handlers, await request.body-text)
    }

    sub request-body(**@handlers) is export {
        run-body-handler(@handlers, await request.body)
    }

    sub run-body-handler(@handlers, \body) {
        for @handlers {
            when Block {
                return .(body) if .signature.ACCEPTS(\(body));
            }
            when Pair {
                with request.content-type -> $content-type {
                    if .key eq $content-type.type-and-subtype {
                        return .value()(body) if .value.signature.ACCEPTS(\(body));
                    }
                }
            }
            default {
                die "request-body handlers can only be a Block or a Pair, not a $_.^name()";
            }
        }
        die X::Cro::HTTP::Router::NoRequestBodyMatch.new;
    }

    proto header(|) is export {*}
    multi header(Cro::HTTP::Header $header --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<header>);
        $resp.append-header($header);
    }
    multi header(Str $header --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<header>);
        $resp.append-header($header);
    }
    multi header(Str $name, Str(Cool) $value --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<header>);
        $resp.append-header($name, $value);
    }

    proto content(|) is export {*}
    multi content(Str $content-type, Blob $body --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<content>);
        $resp.status //= 200;
        $resp.append-header('Content-type', $content-type);
        $resp.set-body($body);
    }
    multi content(Str $content-type, Str $body, :$enc = 'utf-8' --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<content>);
        my $encoded = $body.encode($enc);
        $resp.status //= 200;
        $resp.append-header('Content-type', $content-type ~ '; charset=' ~ $enc);
        $resp.set-body($encoded);
    }

    proto created(|) is export {*}
    multi created(Str() $location --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<content>);
        $resp.status = 201;
        $resp.append-header('Location', $location);
    }
    multi created(Str() $location, $content-type, $body, *%options --> Nil) {
        created $location;
        content $content-type, $body, |%options;
    }

    proto redirect(|) is export {*}
    multi redirect(Str() $location, :$temporary, :$permanent, :$see-other --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<content>);
        if $permanent {
            $resp.status = 308;
        }
        elsif $see-other {
            $resp.status = 303;
        }
        else {
            $resp.status = 307;
        }
        $resp.append-header('Location', $location);
    }
    multi redirect(Str() $location, $content-type, $body, :$temporary,
                   :$permanent, :$see-other, *%options --> Nil) {
        redirect $location, :$permanent, :$see-other;
        content $content-type, $body, |%options;
    }

    proto not-found(|) is export {*}
    multi not-found(--> Nil) {
        set-status(404);
    }
    multi not-found($content-type, $body, *%options --> Nil) {
        set-status(404);
        content $content-type, $body, |%options;
    }

    proto bad-request(|) is export {*}
    multi bad-request(--> Nil) {
        set-status(400);
    }
    multi bad-request($content-type, $body, *%options --> Nil) {
        set-status(400);
        content $content-type, $body, |%options;
    }

    proto forbidden(|) is export {*}
    multi forbidden(--> Nil) {
        set-status(403);
    }
    multi forbidden($content-type, $body, *%options --> Nil) {
        set-status(403);
        content $content-type, $body, |%options;
    }

    proto conflict(|) is export {*}
    multi conflict(--> Nil) {
        set-status(409);
    }
    multi conflict($content-type, $body, *%options --> Nil) {
        set-status(409);
        content $content-type, $body, |%options;
    }

    sub set-status(Int $status --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<content>);
        $resp.status = $status;
    }
}
