use Cro;
use Cro::HTTP::BodyParser;
use Cro::HTTP::BodyParserSelector;
use Cro::HTTP::BodySerializer;
use Cro::HTTP::BodySerializerSelector;
use Cro::HTTP::Request;
use Cro::HTTP::Response;
use IO::Path::ChildSecure;
use Cro::HTTP::MimeTypes;

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
    role Cookie {}
    multi trait_mod:<is>(Parameter:D $param, :$cookie! --> Nil) is export {
        $param does Cookie;
    }

    class RouteSet does Cro::Transform {
        my role Handler {
            has @.prefix;
            has @.body-parsers;
            has @.body-serializers;
            has @.before;
            has @.after;

            method copy-adding() { ... }
            method signature() { ... }
            method invoke(Cro::HTTP::Request $request, Capture $args) { ... }

            method !add-body-parsers(Cro::HTTP::Request $request --> Nil) {
                if @!body-parsers {
                    $request.body-parser-selector = Cro::HTTP::BodyParserSelector::Prepend.new(
                        parsers => @!body-parsers,
                        next => $request.body-parser-selector
                    );
                }
            }

            method !add-body-serializers(Cro::HTTP::Response $response --> Nil) {
                if @!body-serializers {
                    $response.body-serializer-selector = Cro::HTTP::BodySerializerSelector::Prepend.new(
                        serializers => @!body-serializers,
                        next => $response.body-serializer-selector
                    );
                }
            }
        }

        my class RouteHandler does Handler {
            has Str $.method;
            has &.implementation;

            method copy-adding(:@prefix, :@body-parsers!, :@body-serializers!, :@before!, :@after!) {
                self.bless:
                    :$!method, :&!implementation,
                    :prefix[flat @prefix, @!prefix],
                    :body-parsers[flat @!body-parsers, @body-parsers],
                    :body-serializers[flat @!body-serializers, @body-serializers],
                    before => @before.append(@!before),
                    after => @!after.append(@after)
            }

            method signature() {
                &!implementation.signature
            }

            method !invoke-internal(Cro::HTTP::Request $request, Capture $args --> Promise) {
                my $*CRO-ROUTER-REQUEST = $request;
                my $response = my $*CRO-ROUTER-RESPONSE := Cro::HTTP::Response.new(:$request);
                self!add-body-parsers($request);
                self!add-body-serializers($response);
                start {
                    {
                        $request.path eq '/'
                            ?? &!implementation()
                            !! &!implementation(|$args);
                        CATCH {
                            when X::Cro::HTTP::Router::NoRequestBodyMatch {
                                $response.status = 400;
                            }
                            when X::Cro::HTTP::BodyParserSelector::NoneApplicable {
                                $response.status = 400;
                            }
                            default {
                                .note;
                                $response.status = 500;
                            }
                        }
                    }
                    $response.status //= 204;
                    $response
                }
            }

            method invoke(Cro::HTTP::Request $request, Capture $args) {
                if @!before || @!after {
                    my $current = supply emit $request;
                    { $current = $_.transformer($current) } for @!before;
                    supply {
                        whenever $current -> $req {
                            whenever self!invoke-internal($req, $args) {
                                my $response = supply emit $_;
                                $response = $_.transformer($response) for @!after;
                                whenever $response { .emit }
                            }
                        }
                    }
                } else {
                    return self!invoke-internal($request, $args);
                }
            }
        }

        my class DelegateHandler does Handler {
            has Cro::Transform $.transform;
            has Bool $.wildcard;

            method copy-adding(:@prefix, :@body-parsers!, :@body-serializers!, :@before!, :@after!) {
                self.bless:
                    :$!transform,
                    :prefix[flat @prefix, @!prefix],
                    :body-parsers[flat @!body-parsers, @body-parsers],
                    :body-serializers[flat @!body-serializers, @body-serializers],
                    before => @before.append(@!before),
                    after => @!after.append(@after)
            }

            method signature() {
                $!wildcard ?? (-> *@ { }).signature !! (-> {}).signature
            }

            method invoke(Cro::HTTP::Request $request, Capture $args) {
                my $req = $request.without-first-path-segments(@!prefix.elems);
                self!add-body-parsers($req);
                my $current = supply emit $req;
                $current = $_.transformer($current) for @!before;
                supply {
                    whenever $!transform.transformer($current) -> $response {
                        self!add-body-serializers($response);
                        my $res = supply emit $response;
                        $res = $_.transformer($res) for @!after;
                        whenever $res { .emit }
                    }
                }
            }
        }

        has Handler @!handlers;
        has $!path-matcher;
        has Cro::HTTP::BodyParser @!body-parsers;
        has Cro::HTTP::BodySerializer @!body-serializers;
        has @!includes;
        has @!before;
        has @!after;

        method consumes() { Cro::HTTP::Request }
        method produces() { Cro::HTTP::Response }

        method transformer(Supply:D $requests) {
            supply {
                whenever $requests -> $request {
                    my $*CRO-ROUTER-REQUEST = $request;
                    my $*WRONG-METHOD = False;
                    my $*MISSING-UNPACK = False;
                    my @*BIND-FAILS;
                    with $request.path ~~ $!path-matcher {
                        my ($handler-idx, $args) = .ast;
                        my $handler := @!handlers[$handler-idx];
                        whenever $handler.invoke($request, $args) -> $response {
                            emit $response;
                            QUIT {
                                default {
                                    .note;
                                    emit Cro::HTTP::Response.new(:500status, :$request);
                                }
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
                        emit Cro::HTTP::Response.new(:$status, :$request);
                    }
                }
            }
        }

        method add-handler(Str $method, &implementation --> Nil) {
            @!handlers.push(RouteHandler.new(:$method, :&implementation, :@!before, :@!after));
        }

        method add-body-parser(Cro::HTTP::BodyParser $parser --> Nil) {
            @!body-parsers.push($parser);
        }

        method add-body-serializer(Cro::HTTP::BodySerializer $serializer --> Nil) {
            @!body-serializers.push($serializer);
        }

        method include(@prefix, RouteSet $includee) {
            @!includes.push({ :@prefix, :$includee });
        }

        method before($middleware) {
            @!before.push($middleware);
        }
        method after($middleware) {
            @!after.push($middleware);
        }

        method !handlers() { @!handlers }

        method delegate(@prefix, Cro::Transform $transform) {
            my $wildcard = @prefix[*-1] eq '*';
            my @new-prefix = @prefix;
            @new-prefix.pop if $wildcard;
            @!handlers.push(DelegateHandler.new(
                                   prefix => @new-prefix,
                                   :$transform, :$wildcard, before => @!before, after => @!after));
        }

        method definition-complete(--> Nil) {
            for @!handlers {
                .body-parsers = @!body-parsers;
                .body-serializers = @!body-serializers;
            }
            for @!includes -> (:@prefix, :$includee) {
                for $includee!handlers() {
                    @!handlers.push(.copy-adding(:@prefix, :@!body-parsers, :@!body-serializers, :@!before, :@!after));
                }
            }
            self!generate-route-matcher();
        }

        method !generate-route-matcher(--> Nil) {
            my @route-matchers;
            my @handlers = @!handlers; # This is closed over in the EVAL'd regex
            for @handlers.kv -> $index, $handler {
                # Things we need to do to prepare segments for binding and unpack
                # request data.
                my @checks;
                my @make-tasks;
                my @types = int8, int16, int32, int64, uint8, uint16, uint32, uint64;

                # If we need a signature bind test (due to subset/where).
                my $need-sig-bind = False;

                # The prefix is a set of segments that are part of the route
                # that we match, but excluded from the invocation capture that
                # we produce. These are used in include/delegate.
                my @prefix = $handler.prefix.map({ "'$_'" });
                my $prefix-elems = @prefix.elems;

                # Positionals are URL segments, nameds are unpacks of other
                # request data.
                my $signature = $handler.signature;
                my (:@positional, :@named) := $signature.params.classify:
                    { .named ?? 'named' !! 'positional' };

                # Compile segments definition into a matcher.
                my @segments-required;
                my @segments-optional;
                my $segments-terminal = '';

                sub match-types($type,
                                :$lookup, :$target-name,
                                :$seg-index, :@matcher-target, :@constraints) {
                    for @types {
                        if $type === $_ {
                            if $lookup {
                                pack-range($type.^nativesize, !$type.^unsigned,
                                           target => $lookup, :$target-name);
                            } else {
                                pack-range($type.^nativesize, !$type.^unsigned,
                                           :$seg-index, :@matcher-target, :@constraints);
                            }
                            return True;
                        }
                    }
                    False;
                }

                sub pack-range($bits, $signed,
                               :$target, :$target-name, # named
                               :$seg-index, :@matcher-target, :@constraints) {
                    my $bound = 2 ** ($bits - 1);

                    if $target.defined && $target-name.defined {
                        push @checks, '(with ' ~ $target ~ ' { ' ~
                                               ( if $signed {
                                                       -$bound ~ ' <= $_ <= ' ~ $bound - 1
                                                   } else {
                                                     '0 <= $_ <= ' ~ 2 ** $bits - 1
                                                 }
                                               )
                                               ~ '|| !($*MISSING-UNPACK = True)'
                                               ~ ' } else { True })';
                        # we coerce to Int here for two reasons:
                        # * Str cannot be coerced to native types;
                        # * We already did a range check;
                        @make-tasks.push: '%unpacks{Q[' ~ $target-name ~ ']} = .Int with ' ~ $target;
                    } else {
                        my Str $range = $signed ?? -$bound ~ ' <= $_ <= ' ~ $bound - 1 !! '0 <= $_ <= ' ~ 2 ** $bits - 1;
                        my Str $check = '<?{('
                                      ~ Q:c/with @segs[{$prefix-elems + $seg-index}]/
                                      ~ ' {( '~ $range
                                      ~ ' )} else { True }) }>';
                        @matcher-target.push: Q['-'?\d+:] ~ $check;
                        @make-tasks.push: Q:c/.=Int with @segs[{$prefix-elems + $seg-index}]/;
                        $need-sig-bind = True if @constraints;
                    }
                }

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
                                @matcher-target.push("'&encode(@constraints[0])'");
                            }
                            else {
                                # Any match will do, but need bind check.
                                @matcher-target.push('<-[/]>+:');
                                $need-sig-bind = True;
                            }
                        }
                        elsif $type =:= Int || $type =:= UInt {
                            @matcher-target.push(Q['-'?\d+:]);
                            my Str $coerce-prefix = $type =:= Int ?? '.=Int' !! '.=UInt';
                            @make-tasks.push: $coerce-prefix ~
                                Q:c/ with @segs[{$prefix-elems + $seg-index}]/;
                            $need-sig-bind = True if @constraints;
                        }
                        else {
                            my $matched = match-types($type, :$seg-index,
                                                      :@matcher-target, :@constraints);
                            die "Parameter type $type.^name() not allowed on a request unpack parameter" unless $matched;
                        }
                    }
                }
                my $segment-matcher = " '/' " ~
                    (flat @prefix, @segments-required).join(" '/' ") ~
                    @segments-optional.map({ "[ '/' $_ " }).join ~ (' ]? ' x @segments-optional) ~
                    $segments-terminal;

                # Turned nameds into unpacks.
                for @named -> $param {
                    my $target-name = $param.named_names[0];
                    my ($exists, $lookup) = do given $param {
                        when Cookie {
                            '$req.has-cookie(Q[' ~ $target-name ~ '])',
                            '$req.cookie-value(Q[' ~ $target-name ~ '])'
                        }
                        when Header {
                            '$req.has-header(Q[' ~ $target-name ~ '])',
                            '$req.header(Q[' ~ $target-name ~ '])'
                        }
                        default {
                            '$req.query-hash{Q[' ~ $target-name ~ ']}:exists',
                            '$req.query-value(Q[' ~ $target-name ~ '])'
                        }
                    }
                    unless $param.optional {
                        push @checks, '(' ~ $exists ~ ' || !($*MISSING-UNPACK = True))';
                    }

                    my $type := $param.type;
                    if $type =:= Mu || $type =:= Any || $type =:= Str {
                        push @make-tasks, '%unpacks{Q[' ~ $target-name ~ ']} = $_ with ' ~ $lookup;
                    }
                    elsif $type =:= Int || $type =:= UInt {
                        push @checks, '(with ' ~ $lookup ~ ' { so /^"-"?\d+$/ } else { True })';
                        push @make-tasks, '%unpacks{Q[' ~ $target-name ~ ']} = ' ~
                                                        ($type =:= Int ?? '.Int' !! '.UInt')
                                                        ~ ' with ' ~ $lookup;
                    }
                    elsif $type =:= Positional {
                        given $param {
                            when Header {
                                push @make-tasks, '%unpacks{Q[' ~ $target-name ~ ']} = $req.headers';
                            }
                            when Cookie {
                                die "Cookies cannot be extracted to List. Maybe you want '%' instead of '@'";
                            }
                            default {
                                push @make-tasks, '%unpacks{Q[' ~ $target-name ~ ']} = $req.query-hash.List';
                            }
                        }
                    }
                    elsif $type =:= Associative {
                        given $param {
                            when Cookie {
                                push @make-tasks, '%unpacks{Q[' ~ $target-name ~ ']} = $req.cookie-hash';
                            }
                            when Header {
                                push @make-tasks,
                                'my %result;'
                                    ~ '$req.headers.map({ %result{$_.name} = $_.value });'
                                    ~ '%unpacks{Q['
                                    ~ $target-name
                                    ~ ']} = %result;';
                            }
                            default {
                                push @make-tasks, '%unpacks{Q[' ~ $target-name ~ ']} = $req.query-hash'
                            }
                        }
                    }
                    else {
                        my $matched = match-types($type, :$lookup, :$target-name);
                        die "Parameter type $type.^name() not allowed on a request unpack parameter" unless $matched;
                    }
                    $need-sig-bind = True if extract-constraints($param);
                }

                my $method-check = $handler.can('method')
                    ?? '<?{ $req.method eq "' ~ $handler.method ~
                        '" || !($*WRONG-METHOD = True) }>'
                    !! '';
                my $checks = @checks
                    ?? '<?{ ' ~ @checks.join(' and ') ~ ' }>'
                    !! '';
                my $form-cap = '{ my %unpacks; ' ~ @make-tasks.join(';') ~
                    '; $cap = Capture.new(:list(@segs' ~
                    ($prefix-elems ?? "[$prefix-elems..*]" !! "") ~
                    '), :hash(%unpacks)); }';
                my $bind-check = $need-sig-bind
                    ?? '<?{ my $han = @handlers[' ~ $index ~ ']; ' ~
                            '$han.signature.ACCEPTS($cap) || ' ~
                            '!(@*BIND-FAILS.push($han.implementation, $cap)) }>'
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

        sub encode($target) {
            $target.subst: :g, /<-[A..Za..z0..9_~.-]>/, -> Str() $encodee {
                $encodee eq ' '
                    ?? '+'
                    !! $encodee le "\x7F"
                        ?? '%' ~ $encodee.ord.base(16)
                        !! $encodee.encode('utf-8').list.map({ '%' ~ .base(16) }).join
            }
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

    sub body-serializer(Cro::HTTP::BodySerializer $serializer --> Nil) is export {
        $*CRO-ROUTE-SET.add-body-serializer($serializer);
    }

    sub include(*@includees, *%includees --> Nil) is export {
        for @includees {
            when RouteSet  {
                $*CRO-ROUTE-SET.include([], $_);
            }
            when Pair {
                my ($prefix, $routes) = .kv;
                if $routes ~~ RouteSet {
                    given $prefix {
                        when Str {
                            $*CRO-ROUTE-SET.include([$prefix], $routes);
                        }
                        when Iterable {
                            $*CRO-ROUTE-SET.include($prefix, $routes);
                        }
                        default {
                            die "An 'include' prefix may be a Str or Iterable, but not " ~ .^name;
                        }
                    }
                }
                else {
                    die "Can only use 'include' with 'route' block, not a $routes.^name()";
                }
            }
            default {
                die "Can only use 'include' with `route` block, not a " ~ .^name;
            }
        }
        for %includees.kv -> $prefix, $routes {
            if $routes ~~ RouteSet {
                $*CRO-ROUTE-SET.include([$prefix], $routes);
            }
            else {
                die "Can only use 'include' with `route` block, not a $routes.^name()";
            }
        }
    }

    sub delegate(*@delegates, *%delegates --> Nil) is export {
        for flat @delegates, %delegates.pairs {
            when Pair {
                my ($prefix, $transform) = .kv;
                unless $transform ~~ Cro::Transform {
                    die "Pairs passed to 'delegate' must have a Cro::Transform value";
                }
                unless $transform.consumes ~~ Cro::HTTP::Request {
                    die "Transform used with delegate must consume Cro::HTTP::Request, but " ~
                        $transform.^name ~ " consumes " ~ $transform.consumes.^name;
                }
                unless $transform.produces ~~ Cro::HTTP::Response {
                    die "Transform used with delegate must produce Cro::HTTP::Response, but " ~
                        $transform.^name ~ " produces " ~ $transform.produces.^name;
                }
                given $prefix {
                    when Iterable {
                        $*CRO-ROUTE-SET.delegate($prefix, $transform);
                    }
                    when Str {
                        $*CRO-ROUTE-SET.delegate([$prefix], $transform);
                    }
                    default {
                        die "Paris passed to 'delegate' must have a Str or Iterable key, not " ~ .^name;
                    }
                }
            }
            default {
                die "Must pass one or more Pairs to 'delegate', not a " ~ .^name;
            }
        }
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
    multi content(Str $content-type, $body, :$enc = $body ~~ Str ?? 'utf-8' !! Nil --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<content>);
        $resp.status //= 200;
        with $enc {
            $resp.append-header('Content-type', qq[$content-type; charset=$_]);
        }
        else {
            $resp.append-header('Content-type', $content-type);
        }
        $resp.set-body($body);
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

    sub set-cookie($name, $value, *%opts) is export {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<route>);
        $resp.set-cookie($name, $value, |%opts);
    }

    sub set-status(Int $status --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<content>);
        $resp.status = $status;
    }

    sub before($middleware) is export {
        $middleware ~~ Cro::Transform ?? $*CRO-ROUTE-SET.before($middleware) !! ();
    }
    sub after($middleware) is export {
        $middleware ~~ Cro::Transform ?? $*CRO-ROUTE-SET.after($middleware) !! ();
    }

    sub cache-control(:$public, :$private, :$no-cache, :$no-store,
                      Int :$max-age, Int :$s-maxage,
                      :$must-revalidate, :$proxy-revalidate,
                      :$no-transform) is export {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<route>);
        $resp.remove-header('Cache-Control');
        die if ($public, $private, $no-cache).grep(Bool).elems != 1;
        my @headers = (:$public, :$private, :$no-cache, :$no-store,
                       :$max-age, :$s-maxage,
                       :$must-revalidate, :$proxy-revalidate,
                       :$no-transform);
        my $cache = @headers.map(
            {
                if .key eq 'max-age'|'s-maxage' { "{.key}={.value}" if .value }
                else { "{.key}" if .value }
            }).join(', ');
        $resp.append-header('Cache-Control', $cache);
    }

    sub static(Str $base, @path?, :$mime-types) is export {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<route>);
        my $child = '.';
        for @path {
            $child = $child.IO.add: $_;
        }

        my %fallback = $mime-types // {};
        my $ext = $child eq '.' ?? $base.IO.extension !! $child.IO.extension;
        my $content-type = %mime{$ext} // %fallback{$ext} // 'application/octet-stream';

        my sub get_or_404($path) {
            if $path.IO.e {
                content $content-type, slurp($path, :bin);
            } else {
                $resp.status = 404;
            }
        }

        if $child eq '.' {
            get_or_404($base);
        } else {
            with $base.IO.&child-secure: $child {
                get_or_404($_);
            } else {
                $resp.status = 403;
            }
        }
    }
}
