use Cro;
use Cro::BodyParser;
use Cro::BodyParserSelector;
use Cro::BodySerializer;
use Cro::BodySerializerSelector;
use Cro::HTTP::Auth;
use Cro::HTTP::Middleware;
use Cro::HTTP::MimeTypes;
use Cro::HTTP::PushPromise;
use Cro::HTTP::Request;
use Cro::HTTP::Response;
use IO::Path::ChildSecure;

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
    role Auth {}
    multi trait_mod:<is>(Parameter:D $param, :$auth! --> Nil) is export {
        $param does Auth;
    }

    class RouteSet does Cro::Transform {
        role Handler {
            has @.prefix;
            has @.body-parsers;
            has @.body-serializers;
            has @.before-matched;
            has @.after-matched;

            method copy-adding() { ... }
            method signature() { ... }
            method invoke(Cro::HTTP::Request $request, Capture $args) { ... }

            method !add-body-parsers(Cro::HTTP::Request $request --> Nil) {
                if @!body-parsers {
                    $request.body-parser-selector = Cro::BodyParserSelector::Prepend.new(
                        parsers => @!body-parsers,
                        next => $request.body-parser-selector
                    );
                }
            }

            method !add-body-serializers(Cro::HTTP::Response $response --> Nil) {
                if @!body-serializers {
                    $response.body-serializer-selector = Cro::BodySerializerSelector::Prepend.new(
                        serializers => @!body-serializers,
                        next => $response.body-serializer-selector
                    );
                }
            }

            method !append-body-serializers(Supply $pipeline --> Supply) {
                supply whenever $pipeline {
                    self!add-body-serializers($_);
                    emit $_;
                }
            }

            method !append-middleware(Supply $pipeline, @middleware, %connection-state --> Supply) {
                my $current = $pipeline;
                for @middleware -> $comp {
                    if $comp ~~ Cro::ConnectionState {
                        my $cs-type = $comp.connection-state-type;
                        with %connection-state{$cs-type} {
                            $current = $comp.transformer($current, :connection-state($_));
                        }
                        else {
                            my $cs = $cs-type.new;
                            %connection-state{$cs-type} = $cs;
                            $current = $comp.transformer($current, :connection-state($cs));
                        }
                    }
                    else {
                        $current = $comp.transformer($current);
                    }
                }
                $current
            }
        }

        my class RouteHandler does Handler {
            has Str $.method;
            has &.implementation;

            method copy-adding(:@prefix, :@body-parsers!, :@body-serializers!, :@before-matched!, :@after-matched!) {
                self.bless:
                    :$!method, :&!implementation,
                    :prefix[flat @prefix, @!prefix],
                    :body-parsers[flat @!body-parsers, @body-parsers],
                    :body-serializers[flat @!body-serializers, @body-serializers],
                    :before-matched[flat @before-matched, @!before-matched],
                    :after-matched[flat @!after-matched, @after-matched]
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
                        &!implementation(|$args);
                        CATCH {
                            when X::Cro::HTTP::Router::NoRequestBodyMatch {
                                $response.status = 400;
                            }
                            when X::Cro::BodyParserSelector::NoneApplicable {
                                $response.status = 400;
                            }
                            default {
                                .note;
                                $response.status = 500;
                            }
                        }
                    }
                    $response.status //= 204;
                    # Close push promises as we don't get a new ones
                    $response.close-push-promises();
                    $response
                }
            }

            method invoke(Cro::HTTP::Request $request, Capture $args) {
                if @!before-matched || @!after-matched {
                    my $current = supply emit $request;
                    my %connection-state{Mu};
                    $current = self!append-middleware($current, @!before-matched, %connection-state);
                    my $response = supply whenever $current -> $req {
                        whenever self!invoke-internal($req, $args) {
                            emit $_;
                        }
                    }
                    return self!append-middleware($response, @!after-matched, %connection-state);
                } else {
                    return self!invoke-internal($request, $args);
                }
            }
        }

        my class DelegateHandler does Handler {
            has Cro::Transform $.transform;
            has Bool $.wildcard;

            method copy-adding(:@prefix, :@body-parsers!, :@body-serializers!, :@before-matched!, :@after-matched!) {
                self.bless:
                    :$!transform,
                    :prefix[flat @prefix, @!prefix],
                    :body-parsers[flat @!body-parsers, @body-parsers],
                    :body-serializers[flat @!body-serializers, @body-serializers],
                    before-matched => @before-matched.append(@!before-matched),
                    after-matched => @!after-matched.append(@after-matched)
            }

            method signature() {
                $!wildcard ?? (-> *@ { }).signature !! (-> {}).signature
            }

            method invoke(Cro::HTTP::Request $request, Capture $args) {
                my $req = $request.without-first-path-segments(@!prefix.elems);
                self!add-body-parsers($req);
                my $current = supply emit $req;
                my %connection-state{Mu};
                $current = self!append-middleware($current, @!before-matched, %connection-state);
                $current = $!transform.transformer($current);
                $current = self!append-body-serializers($current);
                $current = self!append-middleware($current, @!after-matched, %connection-state);
                $current
            }
        }

        has Handler @.handlers;
        has Cro::BodyParser @.body-parsers;
        has Cro::BodySerializer @.body-serializers;
        has @.includes;
        has @.before;
        has @.after;
        has @.before-matched;
        has @.after-matched;
        has $!path-matcher;
        has @!handlers-to-add;  # Closures to defer adding, so they get all the middleware

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
                        if @*BIND-FAILS {
                            for @*BIND-FAILS -> $imp, \cap {
                                $imp(|cap);
                                CATCH {
                                    when X::TypeCheck::Binding::Parameter {
                                        my $param = .parameter;
                                        if $param.named {
                                            $status = 400;
                                            last;
                                        }
                                        elsif $param ~~ Auth || $param.type ~~ Cro::HTTP::Auth {
                                            $status = 401;
                                            last;
                                        }
                                    }
                                    default {}
                                }
                            }
                        }
                        elsif $*MISSING-UNPACK {
                            $status = 400;
                        }
                        elsif $*WRONG-METHOD {
                            $status = 405;
                        }
                        emit Cro::HTTP::Response.new(:$status, :$request);
                    }
                }
            }
        }

        method add-handler(Str $method, &implementation --> Nil) {
            @!handlers-to-add.push: {
                @!handlers.push(RouteHandler.new(:$method, :&implementation, :@!before-matched, :@!after-matched));
            }
        }

        method add-body-parser(Cro::BodyParser $parser --> Nil) {
            @!body-parsers.push($parser);
        }

        method add-body-serializer(Cro::BodySerializer $serializer --> Nil) {
            @!body-serializers.push($serializer);
        }

        method add-include(@prefix, RouteSet $includee) {
            @!includes.push({ :@prefix, :$includee });
        }

        method add-before($middleware) {
            @!before.push($middleware);
        }
        method add-after($middleware) {
            @!after.push($middleware);
        }

        method add-before-matched($middleware) {
            @!before-matched.push($middleware);
        }
        method add-after-matched($middleware) {
            @!after-matched.push($middleware);
        }

        method add-delegate(@prefix, Cro::Transform $transform) {
            my $wildcard = @prefix[*-1] eq '*';
            my @new-prefix = @prefix;
            @new-prefix.pop if $wildcard;
            @!handlers-to-add.push: {
                @!handlers.push: DelegateHandler.new:
                   prefix => @new-prefix,
                   :$transform, :$wildcard, before-matched => @!before-matched, after-matched => @!after-matched;
           }
        }

        method definition-complete(--> Nil) {
            while @!handlers-to-add.shift -> &add {
                add();
            }
            for @!handlers {
                .body-parsers = @!body-parsers;
                .body-serializers = @!body-serializers;
            }
            for @!includes -> (:@prefix, :$includee) {
                for $includee.handlers() {
                    @!handlers.push: .copy-adding(:@prefix, :@!body-parsers, :@!body-serializers,
                        :@!before-matched, :@!after-matched);
                }
            }
            self!generate-route-matcher();
        }

        method !generate-route-matcher(--> Nil) {
            my @route-matchers;
            my @handlers = @!handlers; # This is closed over in the EVAL'd regex
            for @handlers.kv -> Int $index, Handler $handler {
                push @route-matchers, compile-route($index, $handler);
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

        sub compile-route(Int $index, Handler $handler) {
            # Things we need to do to prepare segments for binding and unpack
            # request data.
            my @checks;
            my @make-tasks;

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

            # If the first segment is an authorization constraint, extract
            # and it and compile the check.
            my $have-auth-param = False;
            with @positional[0] -> $param {
                if $param ~~ Auth || $param.type ~~ Cro::HTTP::Auth {
                    @positional.shift;
                    $have-auth-param = True;
                    $need-sig-bind = True;
                }
            }

            # Compile segments definition into a matcher.
            my @segments-required;
            my @segments-optional;
            my $segments-terminal = '';

            sub match-types($type,
                            :$lookup, :$target-name,
                            :$seg-index, :@matcher-target, :@constraints) {
                my constant @types = int8, int16, int32, int64, uint8, uint16, uint32, uint64;
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
                            push @make-tasks, '%unpacks{Q[' ~ $target-name ~ ']} = $req.query-list';
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
                '; $cap = Capture.new(:list(' ~
                ($have-auth-param
                    ?? '$req.auth' ~ (@positional ?? ', |' !! ',')
                    !! '') ~
                (@positional == 0
                    ?? ''
                    !! '@segs' ~ ($prefix-elems ?? "[$prefix-elems..*]" !! "")) ~
                '), :hash(%unpacks)); }';
            my $bind-check = $need-sig-bind
                ?? '<?{ my $han = @handlers[' ~ $index ~ ']; ' ~
                        '$han.signature.ACCEPTS($cap) || ' ~
                        '!(@*BIND-FAILS.push($han.implementation, $cap)) }>'
                !! '';
            my $make = '{ make (' ~ $index ~ ', $cap) }';
            return join " ",
                $segment-matcher, $method-check, $checks, $form-cap,
                $bind-check, $make;
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

        sub extract-constraints(Parameter:D $param) {
            my @constraints;
            sub extract($v --> Nil) { @constraints.push($v) }
            extract($param.constraints);
            return @constraints;
        }
    }

    sub route(&route-definition) is export {
        my $*CRO-ROUTE-SET = RouteSet.new;
        route-definition();
        $*CRO-ROUTE-SET.definition-complete();
        my @before = $*CRO-ROUTE-SET.before;
        my @after = $*CRO-ROUTE-SET.after;
        if @before || @after {
            return Cro.compose(|@before, $*CRO-ROUTE-SET, |@after, :for-connection);
        } else {
            $*CRO-ROUTE-SET;
        }
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

    sub patch(&handler --> Nil) is export {
        $*CRO-ROUTE-SET.add-handler('PATCH', &handler);
    }

    sub body-parser(Cro::BodyParser $parser --> Nil) is export {
        $*CRO-ROUTE-SET.add-body-parser($parser);
    }

    sub body-serializer(Cro::BodySerializer $serializer --> Nil) is export {
        $*CRO-ROUTE-SET.add-body-serializer($serializer);
    }

    sub include(*@includees, *%includees --> Nil) is export {
        for @includees {
            when RouteSet  {
                $*CRO-ROUTE-SET.add-include([], $_);
            }
            when Pair {
                my ($prefix, $routes) = .kv;
                if $routes ~~ RouteSet {
                    given $prefix {
                        when Str {
                            $*CRO-ROUTE-SET.add-include([$prefix], $routes);
                        }
                        when Iterable {
                            $*CRO-ROUTE-SET.add-include($prefix, $routes);
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
            when Cro::CompositeTransform::WithConnectionState {
                die "Cannot 'include' `route` block that contains before or after middleware, try delegate instead";
            }
            default {
                die "Can only use 'include' with `route` block, not a " ~ .^name;
            }
        }
        for %includees.kv -> $prefix, $routes {
            if $routes ~~ RouteSet {
                $*CRO-ROUTE-SET.add-include([$prefix], $routes);
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
                        $*CRO-ROUTE-SET.add-delegate($prefix, $transform);
                    }
                    when Str {
                        $*CRO-ROUTE-SET.add-delegate([$prefix], $transform);
                    }
                    default {
                        die "Pairs passed to 'delegate' must have a Str or Iterable key, not " ~ .^name;
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
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<created>);
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
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<redirected>);
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
        set-status(404, :action<not-found>);
    }
    multi not-found($content-type, $body, *%options --> Nil) {
        set-status(404, :action<not-found>);
        content $content-type, $body, |%options;
    }

    proto bad-request(|) is export {*}
    multi bad-request(--> Nil) {
        set-status(400, :action<bad-request>);
    }
    multi bad-request($content-type, $body, *%options --> Nil) {
        set-status(400, :action<bad-request>);
        content $content-type, $body, |%options;
    }

    proto forbidden(|) is export {*}
    multi forbidden(--> Nil) {
        set-status(403, :action<forbidden>);
    }
    multi forbidden($content-type, $body, *%options --> Nil) {
        set-status(403, :action<forbidden>);
        content $content-type, $body, |%options;
    }

    proto conflict(|) is export {*}
    multi conflict(--> Nil) {
        set-status(409, :action<conflict>);
    }
    multi conflict($content-type, $body, *%options --> Nil) {
        set-status(409, :action<conflict>);
        content $content-type, $body, |%options;
    }

    sub set-cookie($name, $value, *%opts) is export {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<route>);
        $resp.set-cookie($name, $value, |%opts);
    }

    sub set-status(Int $status, Str :$action = 'set-status' --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what($action));
        $resp.status = $status;
    }

    sub push-promise(Str $path, :$headers) is export {
        with $headers {
            if $headers ~~ Hash {
                push-promise-internal($path, $headers.List)
            } elsif $headers ~~ List {
                push-promise-internal($path, $headers)
            } else {
                die "push-promise headers argument must be a Hash or a List, got {$headers.^name} instead";
            }
        }
        else {
            push-promise-internal($path, []);
        }
    }
    sub push-promise-internal(Str $path, @headers) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<push-promise>);
        # TODO: We don't set http-version anywhere really, so check a request instead.
        # To fix we need to introduce some rules to set appropriate http version
        # during $*CRO-ROUTER-RESPONSE creation.
        return unless ($*CRO-ROUTER-REQUEST.http-version // '') eq '2.0';
        $resp.http-version = '2.0';
        # TODO: target resolution
        my $pp = Cro::HTTP::PushPromise.new(:method<GET>,
                                            target => $path);
        $pp.append-header($_) for @headers;
        $resp.add-push-promise($pp);
    }

    my class BeforeMiddleTransform does Cro::HTTP::Middleware::Conditional {
        has &.block;

        method process(Supply $pipeline --> Supply) {
            supply {
                whenever $pipeline -> $request {
                    my $*CRO-ROUTER-REQUEST := $request;
                    my $*CRO-ROUTER-RESPONSE := Cro::HTTP::Response.new(:$request);
                    &!block($request);
                    emit $*CRO-ROUTER-RESPONSE.status.defined
                        ?? $*CRO-ROUTER-RESPONSE
                        !! $request;
                }
            }
        }
    }

    my class AfterMiddleTransform does Cro::Transform {
        has &.block;

        method consumes() { Cro::HTTP::Response }
        method produces() { Cro::HTTP::Response }

        method transformer(Supply $pipeline --> Supply) {
            supply {
                whenever $pipeline -> $response {
                    my $*CRO-ROUTER-RESPONSE := $response;
                    &!block($response);
                    emit $response;
                }
            }
        }
    }

    multi sub before(Cro::Transform $middleware --> Nil) is export {
        $_ = $middleware;
        if .consumes ~~ Cro::HTTP::Request
        && .produces ~~ Cro::HTTP::Request {
            $*CRO-ROUTE-SET.add-before($_)
        } else {
            die "before middleware must consume and produce Cro::HTTP::Request, got ({.consumes.perl}) and ({.produces.perl}) instead";
        }
    }
    multi sub before(&middleware --> Nil) is export {
        my $conditional = BeforeMiddleTransform.new(block => &middleware);
        $*CRO-ROUTE-SET.add-before($conditional.request);
        $*CRO-ROUTE-SET.add-after($conditional.response);
    }
    multi sub before(Cro::HTTP::Middleware::Pair $pair --> Nil) {
        before($pair.request);
        after($pair.response);
    }

    multi sub after(Cro::Transform $middleware --> Nil) is export {
        $_ = $middleware;
        if .consumes ~~ Cro::HTTP::Response
        && .produces ~~ Cro::HTTP::Response {
            $*CRO-ROUTE-SET.add-after($_)
        } else {
            die "after middleware must consume and produce Cro::HTTP::Response, got ({.consumes.perl}) and ({.produces.perl}) instead";
        }
    }
    multi sub after(&middleware --> Nil) is export {
        my $transformer = AfterMiddleTransform.new(block => &middleware);
        $*CRO-ROUTE-SET.add-after($transformer);
    }

    multi sub before-matched(Cro::Transform $middleware --> Nil) is export {
        $_ = $middleware;
        if .consumes ~~ Cro::HTTP::Request
        && .produces ~~ Cro::HTTP::Request {
            $*CRO-ROUTE-SET.add-before-matched($_)
        } else {
            die "before-matched middleware must consume and produce Cro::HTTP::Request, got ({.consumes.perl}) and ({.produces.perl}) instead";
        }
    }
    multi sub before-matched(&middleware --> Nil) is export {
        my $conditional = BeforeMiddleTransform.new(block => &middleware);
        $*CRO-ROUTE-SET.add-before-matched($conditional.request);
        $*CRO-ROUTE-SET.add-after-matched($conditional.response);
    }
    multi sub before-matched(Cro::HTTP::Middleware::Pair $pair --> Nil) {
        before-matched($pair.request);
        after-matched($pair.response);
    }

    multi sub after-matched(Cro::Transform $middleware --> Nil) is export {
        $_ = $middleware;
        if .consumes ~~ Cro::HTTP::Response
        && .produces ~~ Cro::HTTP::Response {
            $*CRO-ROUTE-SET.add-after-matched($_)
        } else {
            die "after-matched middleware must consume and produce Cro::HTTP::Response, got ({.consumes.perl}) and ({.produces.perl}) instead";
        }
    }
    multi sub after-matched(&middleware --> Nil) is export {
        my $transformer = AfterMiddleTransform.new(block => &middleware);
        $*CRO-ROUTE-SET.add-after-matched($transformer);
    }

    sub http($method, &handler --> Nil) is export {
        $*CRO-ROUTE-SET.add-handler($method, &handler);
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

    sub static(IO() $base, *@path, :$mime-types, :@indexes) is export {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<route>);

        my $child = '.';
        for @path {
            $child = $child.IO.add: $_;
        }
        my %fallback = $mime-types // {};

        sub get-mime($ext) {
            %mime{$ext} // %fallback{$ext} // 'application/octet-stream';
        }

        my sub get_or_404($path) {
            if $path.e {
                if $path.d {
                    for @indexes {
                        my $index = $path.add($_);
                        if $index.e {
                            content get-mime($index.extension), slurp($index, :bin);
                            return;
                        }
                    }
                    $resp.status = 404;
                    return;
                } else {
                    content get-mime($path.extension), slurp($path, :bin);
                }
            } else {
                $resp.status = 404;
            }
        }

        if $child eq '.' {
            get_or_404($base);
        } else {
            with $base.&child-secure: $child {
                get_or_404($_);
            } else {
                $resp.status = 403;
            }
        }
    }
    
    sub static-resource(*@path, :$mime-types, :@indexes) is export {
        my $resp = $*CRO-ROUTER-RESPONSE //
        die X::Cro::HTTP::Router::OnlyInHandler.new(:what<route>);

        my $path = @path.grep(*.so).join: '/';
        my %fallback = $mime-types // {};

        sub get-mime($ext) {
            %mime{$ext} // %fallback{$ext} // 'application/octet-stream';
        }

        sub get-extension($path) {
            return ($path ~~ m/ '.' ( <-[ \. ]>+ ) $ / )[0].Str;
        }

        if $path and my $resource = %?RESOURCES{$path} and $resource.IO.e and !$resource.IO.d {
            content get-mime(get-extension($path)), slurp($resource, :bin);
        } else {
            for @indexes {
                my $index = ($path, $_).grep(*.so).join: '/';
                my $resource = %?RESOURCES{$index};
                if $resource.IO.e {
                    content get-mime(get-extension($index)), slurp($resource, :bin);
                    last;
                }
            }
        }

        $resp.status //= 404;
    }

}
