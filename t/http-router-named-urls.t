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
        is abs-link('qs', 'tools', query => 'abc?!'), '/search/tools?query=abc%3F%21', 'Escaped named param';
        is abs-link('segs', 42, 'foo bar.jpg'), '/product/42/docs/foo%20bar.jpg', 'Escaped positional';
        is abs-link('noqs'), '/baz', 'Non-path related parameters were not counted';
    };

    get :name<lit>, -> 'foo', 'bar' { }
    get :name<segs>, -> 'product', $id, 'docs', $file { }
    get :name<qs>, -> 'search', $category, :$query {}
    get :name<noqs>, -> 'baz', :$foo! is cookie, :$bar! is header {}
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

test-route-urls route :name<main>, {
    get :name<home>, -> {
        is abs-link('main.home'), '/', 'Basic call of a generator by a qualified name is correct';
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

test-route-urls route {
    get -> {
        is abs-link('hello', 'world'), '/hello/world', 'URL is generated correctly';
        throws-like { abs-link('hello') }, Exception, message => "Not enough arguments";
        throws-like { abs-link('hello', 'a', 'b') }, Exception, message => "Extraneous arguments";
    }

    get :name<hello>, -> 'hello', $name {};
}

test-route-urls route {
    get :name<hello>, -> :$a, :$b {
        is abs-link('hello', :a(1), :b(2)), '/?a=1&b=2';
        is abs-link('hello', :a(1)), '/?a=1';
        is abs-link('hello', :b(2)), '/?b=2';
        throws-like { abs-link('hello', 1) }, Exception, message => "Extraneous arguments";
        throws-like { abs-link('hello', :c(3)) }, Exception, message => "Extraneous named arguments: c.";
        throws-like { abs-link('hello', :a(1), :c(3)) }, Exception, message => "Extraneous named arguments: c.";
    };
}

test-route-urls route {
    get -> {
        is abs-link('hello', :a(1), :b(2)), '/?a=1&b=2';
        throws-like { abs-link('hello', :a(1)) }, Exception, message => "Missing named arguments: b.";
        throws-like { abs-link('hello', :b(2)) }, Exception, message => "Missing named arguments: a.";
        throws-like { abs-link('hello', 1) }, Exception, message => "Extraneous arguments";
        throws-like { abs-link('hello', :c(3)) }, Exception, message => "Missing named arguments: a, b. Extraneous named arguments: c.";
        throws-like { abs-link('hello', :a(1), :c(3)) }, Exception, message => "Missing named arguments: b. Extraneous named arguments: c.";
    }

    get :name<hello>, -> :$a!, :$b! {};
}

test-route-urls route {
    get -> {
        is abs-link('css'), '/css';
        is abs-link('css', 'x', 'y', 'z'), '/css/x/y/z';
    }

    get :name<css>, -> 'css', +a { };
}

test-route-urls route {
    get -> {
        is abs-link('css'), '/', 'Splat with no args at all';
        is abs-link('css', 'x', 'y', 'z'), '/x/y/z', 'Splat with no named args';
        is abs-link('css', :a(1), :b(2), :c(3)), '/?a=1&b=2&c=3', 'Splat with no pos args';
        is abs-link('css', 'x', 'y', 'z', :a(1), :b(2), :où('Ÿ')), '/x/y/z?a=1&b=2&o%C3%B9=%C5%B8', 'Splat with both types of args';
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
