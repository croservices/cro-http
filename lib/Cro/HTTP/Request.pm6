use Cro::BodyParserSelector;
use Cro::BodySerializerSelector;
use Cro::HTTP::Cookie;
use Cro::HTTP::BodyParserSelectors;
use Cro::HTTP::BodySerializerSelectors;
use Cro::HTTP::Message;
use Cro::TLS;
use Cro::Uri::HTTP;

class X::Cro::HTTP::Request::Incomplete is Exception {
    has $.missing;
    method message() {
        "Cannot serialize a HTTP request missing its $!missing"
    }
}

#| A HTTP request. In a client context, this is a request to be sent to the
#| server. In a server context, this is a request received from the client to
#| be processed.
class Cro::HTTP::Request does Cro::HTTP::Message {
    has Cro::Uri::HTTP $!cached-uri;
    has Str $!cached-uri-target = '';

    #| An object deciding how the request body is parsed; used in a server
    #| context
    has Cro::BodyParserSelector $.body-parser-selector is rw =
        Cro::HTTP::BodyParserSelector::RequestDefault;

    #| An object deciding how the request body is serialized; used in a client
    #| context
    has Cro::BodySerializerSelector $.body-serializer-selector is rw =
        Cro::HTTP::BodySerializerSelector::RequestDefault;

    #| The connection object that the request arrived on
    has $.connection is rw;

    # This one is a little interesting. Per RFC 7230, "The method token
    # indicates the request method to be performed on the target resource.
    # The request method is case-sensitive." All of the registered names are
    # uppercase. While it is feasible that some day somebody might decide to
    # introduce a custom lower-case one, that seems massively less likely
    # than somebody sticking 'get' instead of 'GET' into a request and having
    # a server (quite rightly) choke on it. So, we'll limit it here. Also, in
    # theory a whole bunch of other chars can be in the method, but again, that
    # seems relatively unlikley to happen in reality.
    subset Method of Str where /^<[A..Z]>+$/;

    #| The HTTP method of the request
    has Method $.method is rw;

    # This is relativley liberal, just enforcing Latin-1 and no controls. As it
    # rules out space, we can't malform messages.
    subset Target of Str where /^<[\x21..\xFF]>+$/;

    #| The target of the request. If the request was delegated, a prefix may have
    #| been stripped; use original-target for the target exactly as received
    has Target $.target is rw;

    #| The original target of the request
    has Str $.original-target;

    #| This property carries information about the authority making the request
    #| and may be populated with whatever object the application chooses. In a
    #| HTTP service it may contain information from a verified web token; in a
    #| HTTP application it may contain information about an ongoing session,
    #| together with information on - or a way to check - user rights.
    has $.auth is rw;

    # The request URI, used when the request is issued by the client. For the
    # server side, we try to recreate it from the parts.
    has Cro::Uri $!request-uri;

    #| Extra annotations placed on a request, to facilitate things like request
    #| logging (not recommended for application-level use)
    has %.annotations;

    submethod TWEAK(:$!request-uri = Nil) { }

    #| The HTTP request as a string, including the request line and any headers;
    #| in HTTP/1.1, this is what shall be sent over the network, while in other
    #| HTTP versions it is just informative
    multi method Str(Cro::HTTP::Request:D:) {
        die X::Cro::HTTP::Request::Incomplete.new(:missing<method>) unless $!method;
        die X::Cro::HTTP::Request::Incomplete.new(:missing<target>) unless $!target;
        my $version = self.http-version // (self.has-header('Host') ?? '1.1' !! '1.0');
        $version = '1.1' if $version eq '2.0';
        my $headers = self!headers-str();
        "$.method $.target HTTP/$version\r\n$headers\r\n"
    }

    method trace-output(--> Str) {
        "HTTP Request\n" ~ self.Str.trim.subst("\r\n", "\n", :g).indent(2)
    }

    #| The path portion of the request URI, derived from the target
    method path() {
        self!ensure-cached-uri();
        $!cached-uri.path
    }

    #| A list of path segments of the request URI, derived from the target
    method path-segments() {
        self!ensure-cached-uri();
        $!cached-uri.path-segments
    }

    #| The original target of the request
    method original-target() {
        $!original-target // $!target
    }

    #| The path portion of the request URI, derived from the original target
    method original-path() {
        Cro::Uri::HTTP.parse-request-target(self.original-target())
    }

    #| A list of path segments of the request URI, derived from the original
    #| target
    method original-path-segments() {
        Cro::Uri::HTTP.parse-request-target(self.original-target()).path-segments
    }

    #| A copy of this request object, but with the first n path segments removed
    method without-first-path-segments(Int $n) {
        self.clone(
            original-target => $!original-target // $!target,
            target => '/' ~ $!target.split('/')[$n+1..*].join('/') # We assume leading slash is always provided
        )
    }

    method !ensure-cached-uri(--> Nil) {
        if $!cached-uri-target ne $!target {
            $!cached-uri = Cro::Uri::HTTP.parse-request-target($!target);
            $!cached-uri-target = $!target;
        }
    }

    #| The query portion of the target
    method query() {
        self!ensure-cached-uri();
        $!cached-uri.query
    }

    #| A list of Pair objects representing the key/value pairs in the query
    #| string in the order they were provided
    method query-list() {
        self!ensure-cached-uri();
        $!cached-uri.query-list
    }

    #| A hash mapping query string keys to values
    method query-hash() {
        self!ensure-cached-uri();
        $!cached-uri.query-hash
    }

    #| Look up a value in the query string hash
    method query-value(Str() $key) {
        self.query-hash.{$key}
    }

    method !unpack-cookie(--> List) {
        my @str = self.headers.grep({ .name.lc eq 'cookie' });
        return () if @str.elems == 0;
	@str = self.http-version.defined && self.http-version eq '2.0'
		?? @str.map({ .value.split(/';' ' '?/).List })[*;*]
		!! @str[0].value.split(/';' ' '?/).List;
        my @res;
        for @str {
            CATCH {
                when X::TypeCheck::Assignment {
                    # Skip cookies with invalid name or value. Since they're received from a client we must not die. But
                    # neither we're obliged to maintain them.
                    .rethrow unless .symbol eq '$!value' | '$!name';
                    next
                }
            }
            my ($name, $value) = $_.split('=');
            @res.push: Cro::HTTP::Cookie.new(:$name, :$value) if $name;
        }
        @res;
    }

    method !pack-cookie(*@cookies) {
        self.remove-header('Cookie');
        return if @cookies.elems == 0;
        self.append-header('Cookie',
                           @cookies.map({ $_.to-cookie; }).join('; '));
    }

    #| Check if the request contains a value for a particular cookie
    method has-cookie(Str $name --> Bool) {
        self!unpack-cookie.grep({ $_.name eq $name }).elems == 1
    }

    #| Get the value of the cookie with the specified name; returns Nil if
    #| no such cookie
    method cookie-value(Str $name --> Str) {
        for self!unpack-cookie {
            return $_.value if $_.name eq $name
        }
        Nil;
    }

    #| Get a hash of all cookies sent with the request
    method cookie-hash(--> Hash) {
        my %result;
        for self!unpack-cookie {
            %result{$_.name} = $_.value
        };
        %result;
    }

    #| Add a cookie to the HTTP request by providing a Cro::HTTP::Cookie
    #| object
    multi method add-cookie(Cro::HTTP::Cookie $c --> Bool) {
        my @cookies = self!unpack-cookie;
        my @all-other = @cookies.grep({ not $_.name eq $c.name });
        self!pack-cookie($c, |@all-other);
        @cookies.elems !== @all-other.elems
    }

    #| Add a cookie to the HTTP request by specifying its name and value
    multi method add-cookie(Str $name, Str() $value --> Bool) {
        self.add-cookie(Cro::HTTP::Cookie.new(:$name, :$value));
    }

    #| Remove the cookie with the specified name from the request; returns
    #| True if something was actually removed
    method remove-cookie(Str $name --> Bool) {
        my @cookies = self!unpack-cookie;
        my @res = @cookies.grep({ not $_.name eq $name });
        self!pack-cookie(|@res);
        @res.elems !== @cookies.elems;
    }

    #| Get the URI that was requested. In a client context, this is set by the
    #| HTTP client. In a server context, it is reconstructed based on the
    #| connection object and Host header.
    method uri(--> Cro::Uri) {
        with $!request-uri {
            # It's a client-issued request, so send the URI that was requested.
            $_
        }
        orwith $!connection {
            # It's a server-side request; assemble it from information available.
            my $scheme = $!connection ~~ Cro::TLS::ServerConnection ?? 'https' !! 'http';
            my $base = do with self.header('host') -> $authority {
                Cro::Uri.new(:$scheme, :$authority)
            }
            else {
                Cro::Uri.new: :$scheme, :host($!connection.?socket-host // 'localhost'),
                    :port($!connection.?socket-port // ($scheme eq 'https' ?? 443 !! 80))
            }
            $base.add(self.original-target)
        }
        else {
            # No idea how to provide it
            Nil
        }
    }
}
