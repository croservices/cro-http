use Cro;
use Cro::HTTP::Request;
use Cro::HTTP::Router :link;
use Cro::HTTP::Router :plugin;
use Cro::HTTP::Router;
use Test;

sub test-route-urls($app) {
    my $source = Supplier.new;
    my $responses = $app.transformer($source.Supply).Channel;
    $source.emit(Cro::HTTP::Request.new(:method<GET>, :target</>));
    $responses.receive;
}

test-route-urls route {
    get -> {
        is-deeply router-plugin-get-innermost-configs($link-plugin)[0].link-generators, %(), "No named urls";
    };
}

test-route-urls route :name<main->, {
    get -> {
        is-deeply router-plugin-get-innermost-configs($link-plugin)[0].link-generators, %(), "No named urls with a prefix";
    };
}

{
    my $*CRO-ROOT-URL = 'https://foobar.com';
    test-route-urls route {
        get :name<home>, -> {
            is make-link('home'), '/', 'Basic call of a generator is correct';
            is make-link('home').relative, '', 'Relative URL is correct';
            is make-link('home').absolute, '/', 'Absolute URL is correct';
            is make-link('home').url, 'https://foobar.com/', 'CRO-ROOT-URL was used';
        };
    }
}

test-route-urls route :name<main>, {
    get :name<home>, -> {
        is make-link('main.home'), '/', 'Basic call of a generator by a short name is correct';
    };
}

throws-like {
    route {
        get :name<home>, -> {};
        get :name<home>, -> {};
    }
}, X::Cro::HTTP::Router::DuplicateLinkName, message => "Conflicting link name: home";

throws-like {
    route :name<main>, {
        get :name<home>, -> {};
        get :name<home>, -> {};
    }
}, X::Cro::HTTP::Router::DuplicateLinkName, message => "Conflicting link name: main.home";

# XXX the test intention is bogus?
# We basically have two sorts of cases:
# * A route is not from include for sure, so we append its possible name to possible names of routes
# * A route is from include, so we entrust it to settle the name for itself (because the addressing happens from each individual route bottom-top way
# For the code below, it assumes we should squash the hierarchy when the include is anonymous, but this is forbidden because we explicitly allow:
#         my $app = route {
#            include route {
#                get :name<home>, -> {}
#            }
#            include route {
#                get :name<home>, -> {}
#            }
#        }
# to exist, implying we do not peek into "anonymous" includes
#{
#    my $app = route :name<main>, {
#        include route {
#            get :name<home>, -> {};
#        }
#    }
#    is-deeply $app.urls.keys, ('main.home',), "A named url in an include with a prefix";
#}

test-route-urls route {
    get -> {
        say make-link('hello', 'world');
        is make-link('hello', 'world'), '/hello/world', 'URL is generated correctly';
        throws-like { make-link('hello') }, Exception, message => "Not enough arguments";
        throws-like { make-link('hello', 'a', 'b') }, Exception, message => "Extraneous arguments";
    }

    get :name<hello>, -> 'hello', $name {};
}

test-route-urls route {
    get :name<hello>, -> :$a, :$b {
        is make-link('hello', :a(1), :b(2)), '/?a=1&b=2';
        is make-link('hello', :a(1)), '/?a=1';
        is make-link('hello', :b(2)), '/?b=2';
        throws-like { make-link('hello', 1) }, Exception, message => "Extraneous arguments";
        throws-like { make-link('hello', :c(3)) }, Exception, message => "Extraneous named arguments: c.";
        throws-like { make-link('hello', :a(1), :c(3)) }, Exception, message => "Extraneous named arguments: c.";
    };
}

test-route-urls route {
    get -> {
        is make-link('hello', :a(1), :b(2)), '/?a=1&b=2';
        throws-like { make-link('hello', :a(1)) }, Exception, message => "Missing named arguments: b.";
        throws-like { make-link('hello', :b(2)) }, Exception, message => "Missing named arguments: a.";
        throws-like { make-link('hello', 1) }, Exception, message => "Extraneous arguments";
        throws-like { make-link('hello', :c(3)) }, Exception, message => "Missing named arguments: a, b. Extraneous named arguments: c.";
        throws-like { make-link('hello', :a(1), :c(3)) }, Exception, message => "Missing named arguments: b. Extraneous named arguments: c.";
    }

    get :name<hello>, -> :$a!, :$b! {};
}

test-route-urls route {
    get -> {
        is make-link('css'), '/css';
        is make-link('css', 'x', 'y', 'z'), '/css/x/y/z';
    }

    get :name<css>, -> 'css', +a { };
}

test-route-urls route {
    get -> {
        is make-link('css'), '/', 'Splat with no args at all';
        is make-link('css', 'x', 'y', 'z'), '/x/y/z', 'Splat with no named args';
        is make-link('css', :a(1), :b(2), :c(3)), '/?a=1&b=2&c=3', 'Splat with no pos args';
        is make-link('css', 'x', 'y', 'z', :a(1), :b(2), :où('Ÿ')), '/x/y/z?a=1&b=2&o%C3%B9=%C5%B8', 'Splat with both types of args';
    }

    get :name<css>, -> *@a, *%b { };
}

{
    lives-ok {
        my $app = route {
            include route {
                get :name<home>, -> {};
            }
            include route {
                get :name<home>, -> {};
            }
        }
    }, 'Conflict check is per-route block 1';
}

{
    lives-ok {
        my $app = route {
            get :name<simple>, -> {};
            include route {
                get :name<home>, -> {};
                get :name<homeA>, -> {};
            }
            include route :name<secondRoute>, {
                get :name<home>, -> {};
                get :name<homeB>, -> {};
            }
        }
    }, 'Conflict check is per-route block 2';
}

{
    lives-ok {
        my $app = route {
            include route :name<foo>, {
                get :name<home>, -> {};
            }
            include route :name<bar>, {
                get :name<home>, -> {};
            }
        }
    }, 'Conflict check is by route name';
}

throws-like {
    my $app = route {
        include route :name<foo>, {
            get :name<home>, -> {};
        }
        include route :name<foo>, {
            get :name<home>, -> {};
        }
    }
}, X::Cro::HTTP::Router::DuplicateLinkName, message => "Conflicting link name: foo.home";

done-testing;
