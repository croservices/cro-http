use Cro::HTTP::Cookie;
use Cro::HTTP::BodyParserSelector;
use Cro::HTTP::BodySerializerSelector;
use Cro::HTTP::Message;
use Cro::Uri::HTTP;

class X::Cro::HTTP::Request::Incomplete is Exception {
    has $.missing;
    method message() {
        "Cannot serialize a HTTP request missing its $!missing"
    }
}

class Cro::HTTP::Request does Cro::HTTP::Message {
    has Cro::Uri::HTTP $!cached-uri;
    has Str $!cached-uri-target = '';
    has Cro::HTTP::BodyParserSelector $.body-parser-selector is rw =
        Cro::HTTP::BodyParserSelector::RequestDefault;
    has Cro::HTTP::BodySerializerSelector $.body-serializer-selector is rw =
        Cro::HTTP::BodySerializerSelector::RequestDefault;
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
    has Method $.method is rw;

    # This is relativley liberal, just enforcing Latin-1 and no controls. As it
    # rules out space, we can't malform messages.
    subset Target of Str where /^<[\x21..\xFF]>+$/;
    has Target $.target is rw;
    has Str $.original-target;

    multi method Str(Cro::HTTP::Request:D:) {
        die X::Cro::HTTP::Request::Incomplete.new(:missing<method>) unless $!method;
        die X::Cro::HTTP::Request::Incomplete.new(:missing<target>) unless $!target;
        my $version = self.http-version // (self.has-header('Host') ?? '1.1' !! '1.0');
        my $headers = self!headers-str();
        "$.method $.target HTTP/$version\r\n$headers\r\n"
    }

    method trace-output(--> Str) {
        "HTTP Request\n" ~ self.Str.trim.subst("\r\n", "\n", :g).indent(2)
    }

    method path() {
        self!ensure-cached-uri();
        $!cached-uri.path
    }

    method path-segments() {
        self!ensure-cached-uri();
        $!cached-uri.path-segments
    }

    method original-target() {
        $!original-target // $!target
    }

    method original-path() {
        Cro::Uri::HTTP.parse-request-target(self.original-target())
    }

    method original-path-segments() {
        Cro::Uri::HTTP.parse-request-target(self.original-target()).path-segments
    }

    method without-first-path-segments($n) {
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

    method query() {
        self!ensure-cached-uri();
        $!cached-uri.query
    }

    method query-hash() {
        self!ensure-cached-uri();
        $!cached-uri.query-hash
    }

    method query-value(Str() $key) {
        self.query-hash.{$key}
    }

    method !unpack-cookie(--> List) {
        my @str = self.headers.grep({ .name.lc eq 'cookie' });
        return () if @str.elems == 0;
        @str = @str[0].value.split('; ').List;
        my @res;
        for @str {
            my ($name, $value) = $_.split('=');
            @res.push: Cro::HTTP::Cookie.new(:$name, :$value);
        }
        @res;
    }

    method !pack-cookie(*@cookies) {
        self.remove-header('Cookie');
        return if @cookies.elems == 0;
        self.append-header('Cookie',
                           @cookies.map({ $_.to-cookie; }).join('; '));
    }

    method has-cookie(Str $name --> Bool) {
        self!unpack-cookie.grep({ $_.name eq $name }).elems == 1
    }

    method cookie-value(Str $name --> Str) {
        for self!unpack-cookie {
            return $_.value if $_.name eq $name
        }
        Nil;
    }

    method cookie-hash(--> Hash) {
        my %result;
        for self!unpack-cookie {
            %result{$_.name} = $_.value
        };
        %result;
    }

    multi method add-cookie(Cro::HTTP::Cookie $c --> Bool) {
        my @cookies = self!unpack-cookie;
        my @all-other = @cookies.grep({ not $_.name eq $c.name });
        self!pack-cookie($c, |@all-other);
        @cookies.elems !== @all-other.elems
    }
    multi method add-cookie(Str $name, Str() $value --> Bool) {
        self.add-cookie(Cro::HTTP::Cookie.new(:$name, :$value));
    }

    method remove-cookie(Str $name --> Bool) {
        my @cookies = self!unpack-cookie;
        my @res = @cookies.grep({ not $_.name eq $name });
        self!pack-cookie(|@res);
        @res.elems !== @cookies.elems;
    }
}
