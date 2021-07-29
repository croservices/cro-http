use Cro;
use Cro::HTTP::Request;
use Cro::HTTP::Router;
use Test;

{
    my $app = route {
        get -> {};
    }
    is-deeply $app.urls, %(), "No named urls";
}

{
    my $app = route :name<main->, {
        get -> {};
    }
    is-deeply $app.urls, %(), "No named urls with a prefix";
}

{
    my $*CRO-ROOT-URL = 'https://foobar.com';
    my $app = route {
        get :name<home>, -> {};
    }
    is-deeply $app.urls.keys, ('home',), "A named url with no prefix";
    is $app.urls<home>(), '/';
    is $app.urls<home>.relative, '';
    is $app.urls<home>.absolute, '/';
    is $app.urls<home>.url, 'https://foobar.com/';
}

{
    my $app = route :name<main->, {
        get :name<home>, -> {};
    }
    is-deeply $app.urls.keys, ('main-home',), "A named url with a prefix";
    is $app.urls<main-home>(), '/';
}

throws-like {
    route {
        get :name<home>, -> {};
        get :name<home>, -> {};
    }
}, X::Cro::HTTP::Router::DuplicateLinkName, message => "Conflicting link name: home";

throws-like {
    route :name<main->, {
        get :name<home>, -> {};
        get :name<home>, -> {};
    }
}, X::Cro::HTTP::Router::DuplicateLinkName, message => "Conflicting link name: main-home";

{
    my $app = route :name<main->, {
        include route {
            get :name<home>, -> {};
        }
    }
    is-deeply $app.urls.keys, ('main-home',), "A named url in an include with a prefix";
}

{
    my $app = route {
        get :name<hello>, -> 'hello', $name { };
    }
    is $app.urls<hello>('world'), '/hello/world';
    throws-like { $app.urls<hello>() }, Exception, message => "Not enough arguments";
    throws-like { $app.urls<hello>('a', 'b') }, Exception, message => "Extraneous arguments";
}

{
    my $app = route {
        get :name<hello>, -> :$a, :$b { };
    }
    is $app.urls<hello>(:a(1), :b(2)), '/?a=1&b=2';
    is $app.urls<hello>(:a(1)), '/?a=1';
    is $app.urls<hello>(:b(2)), '/?b=2';
    throws-like { $app.urls<hello>(1) }, Exception, message => "Extraneous arguments";
    throws-like { $app.urls<hello>(:c(3)) }, Exception, message => "Extraneous named arguments: c.";
    throws-like { $app.urls<hello>(:a(1), :c(3)) }, Exception, message => "Extraneous named arguments: c.";
}

{
    my $app = route {
        get :name<hello>, -> :$a!, :$b! { };
    }
    is $app.urls<hello>(:a(1), :b(2)), '/?a=1&b=2';
    throws-like { $app.urls<hello>(:a(1)) }, Exception, message => "Missing named arguments: b.";
    throws-like { $app.urls<hello>(:b(2)) }, Exception, message => "Missing named arguments: a.";
    throws-like { $app.urls<hello>(1) }, Exception, message => "Extraneous arguments";
    throws-like { $app.urls<hello>(:c(3)) }, Exception, message => "Missing named arguments: a, b. Extraneous named arguments: c.";
    throws-like { $app.urls<hello>(:a(1), :c(3)) }, Exception, message => "Missing named arguments: b. Extraneous named arguments: c.";
}

{
    my $app = route {
        get :name<css>, -> 'css', +a { };
    }
    is $app.urls<css>(), '/css';
    is $app.urls<css>('x', 'y', 'z'), '/css/x/y/z';
}

{
    my $app = route {
        get :name<css>, -> *@a, *%b { };
    }
    is $app.urls<css>(), '/', 'Splat with no args at all';
    is $app.urls<css>('x', 'y', 'z'), '/x/y/z', 'Splat with no named args';
    is $app.urls<css>(:a(1), :b(2), :c(3)), '/?a=1&b=2&c=3', 'Splat with no pos args';
    is $app.urls<css>('x', 'y', 'z', :a(1), :b(2), :où('Ÿ')), '/x/y/z?a=1&b=2&o%C3%B9=%C5%B8', 'Splat with both types of args';
}

# TODO before/after
# TODO include should not trigger name conflicts

done-testing;