use Cro::HTTP::Cookie;
use Cro::Uri;
use Cro::HTTP::Response;
use Cro::HTTP::Request;
use OO::Monitors;

my class CookieState {
    has Cro::HTTP::Cookie $.cookie is rw;
    has DateTime $.expiry-time is rw;
    has DateTime $.creation-time is rw;
    has DateTime $.last-access-time is rw;
    has Bool $.persistent is rw;
    has Bool $.host-only is rw;
    has Bool $.secure-only is rw;
    has Bool $.http-only is rw;
}

monitor Cro::HTTP::Client::CookieJar {
    has CookieState @!cookies;

    method !purge() {
        my @replacer;
        for @!cookies {
            if .expiry-time > DateTime.now {
                @replacer.push: $_;
            }
        }
        @!cookies = @replacer;
    }

    method !domain-match(Str $string, Str $domain --> Bool) {
        return True if $string eq $domain;
        $domain.ends-with(".$string"); # check is it IP address?
    }

    method !default-path(Cro::Uri $uri --> Str) {
        my $path = $uri.path;
        return '/' if $path eq '' || !$path.starts-with('/');
        return '/' if $path eq '/';
        my $index = rindex $path, '/' - 1;
        $path.comb[0..$index].join;
    }

    method !path-match(Str $path, Str $request-path) {
        return True if $request-path eq $path;
        return True if $request-path.starts-with($path) && $path.ends-with('/');
        return True if $request-path.starts-with("$path/");
        False
    }

    method add-from-response(Cro::HTTP::Response $resp, Cro::Uri $uri) {
        my $state;
        my $domain;
        my $path;

        for $resp.cookies {
            $state = CookieState.new(creation-time => DateTime.now,
                                     last-access-time => DateTime.now);
            if $_.max-age.defined {
                $state.persistent = True;
                $state.expiry-time = DateTime.now.later(seconds => $_.max-age)
            }
            elsif !$_.max-age.defined && $_.expires {
                $state.presistent = True;
                $state.expiry-time = $_.expires;
            } else {
                $state.persistent = False;
                $state.expiry-time = DateTime.now.later(years => 10);
            }

            $domain = $_.domain // '';
            if not $domain eq '' {
                next unless self!domain-match($domain, $uri.host);
                $state.host-only = False;
            } else {
                $state.host-only = True;
                $domain = $uri.host;
            }
            $path = $_.path // self!default-path($uri);
            $state.secure-only = $_.secure // False;
            $state.http-only = $_.http-only // False;
            next if $state.http-only && not $uri.scheme eq 'http';

            # Uniqueness check
            sub checker($_, $cs) {
                $cs.cookie.name eq $_.name &&
                $cs.cookie.domain eq $domain &&
                $cs.cookie.path eq $path
            };
            my @set = @!cookies.grep(-> $cs { checker($_, $cs) });
            if @set.elems != 0 {
                next if @set[0].http-only && not $uri.scheme eq 'http';
                $state.creation-time = @set[0].creation-time;
            }
            @!cookies = @!cookies.grep(-> $cs { !checker($_, $cs) });
            @!cookies.push: $state.clone(cookie => $_.clone(:$domain, :$path));
        }
        self!purge;
    };

    method add-to-request(Cro::HTTP::Request $req, Cro::Uri $uri) {
        self!purge;
        my @cookie-list;
        my $checker = {
            ( .host-only && $uri.host eq .cookie.domain ||
              !.host-only && self!domain-match(.cookie.domain, $uri.host) ) &&
            ( self!path-match($_.cookie.path, $uri.path)                  ) &&
            ( .secure-only ?? $uri.scheme eq 'https' !! True              ) &&
            ( .http-only   ?? $uri.scheme eq 'http'  !! True              )
        };
        @!cookies.map({
            if $checker($_) {
                .last-access-time = DateTime.now;
                @cookie-list.push: .cookie;
            };
        });
        # Sorting
        @cookie-list.sort({ $^a.path.comb.elems cmp $^b.path.comb.elems });
        # TODO: sort by .creation-time too

        @cookie-list.map({ $req.add-cookie($_) });
    };

    multi method contents(--> List) { @!cookies };
    multi method contents(Cro::Uri $uri --> List) {
        my $condition = { $uri.host eq .domain || $uri.host.ends-with(".$_.domain"); };
        @!cookies.grep({ $condition($_.cookie) }).List;
    };

    multi method clear() { @!cookies = () };
    multi method clear($uri) {
        my $condition = { $uri.host eq .domain || $uri.host.ends-with(".$_.domain"); };
        @!cookies .= grep({ not $condition($_.cookie) });
    };
    multi method clear(Cro::Uri $uri, Str $name) {
        my $condition = -> $_ {
            ($uri.host eq .domain || $uri.host.ends-with(".$_.domain"))
            && .name eq $name; };
        @!cookies .= grep({ not $condition($_.cookie) });
    };
}
