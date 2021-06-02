use Cro::HTTP::Router;
use Cro::HTTP::Router :plugin;
use Test;

my $plugin-key = router-plugin-register('just-a-test');

sub add-message(Str $message) {
    if router-plugin-get-innermost-configs($plugin-key, error-sub => 'add-message') < 2 {
        router-plugin-add-config($plugin-key, $message, error-sub => 'add-message');
    }
    else {
        die "Too many messages";
    }
}

sub my-messages() {
    router-plugin-get-innermost-configs($plugin-key).join(",")
}

sub all-messages() {
    router-plugin-get-configs($plugin-key).join(",")
}

throws-like { add-message('xxx') },
        X::Cro::HTTP::Router::OnlyInRouteBlock,
        what => 'add-message',
        'router-plugin-add-config throws outside of route block';

my $test-inner = route {
    add-message 'i1';
    lives-ok { add-message 'i2' }, 'Can add plugin configuration to the route block';
    dies-ok { add-message 'i3' }, 'Got expected error from add-message';

    get -> 'inner-my' {
        content 'text/plain', my-messages()
    }

    get -> 'inner-all' {
        content 'text/plain', all-messages()
    }
}

subtest 'Access to configuration with single level route block' => {
    my $in = Supplier.new;
    my Channel $out = $test-inner.transformer($in.Supply).Channel;

    $in.emit: Cro::HTTP::Request.new(http-version => '1.1', method => 'GET', target => '/inner-my');
    given $out.receive {
        isa-ok $_, Cro::HTTP::Response, 'Got a response';
        my $body = await .body-text;
        is-deeply $body, 'i1,i2', 'Local configuration was available in route handler';
    }

    $in.emit: Cro::HTTP::Request.new(http-version => '1.1', method => 'GET', target => '/inner-all');
    given $out.receive {
        isa-ok $_, Cro::HTTP::Response, 'Got a response';
        my $body = await .body-text;
        is-deeply $body, 'i1,i2', 'All configuration was available in route handler';
    }
}

my $test-outer = route {
    add-message 'o1';
    include $test-inner;
    add-message 'o2';

    get -> 'outer-my' {
        content 'text/plain', my-messages()
    }

    get -> 'outer-all' {
        content 'text/plain', all-messages()
    }
}

subtest 'Access to configuration with include' => {
    my $in = Supplier.new;
    my Channel $out = $test-outer.transformer($in.Supply).Channel;

    $in.emit: Cro::HTTP::Request.new(http-version => '1.1', method => 'GET', target => '/inner-my');
    given $out.receive {
        isa-ok $_, Cro::HTTP::Response, 'Got a response';
        my $body = await .body-text;
        is-deeply $body, 'i1,i2', 'Local configuration in included route handler not affected by outer';
    }

    $in.emit: Cro::HTTP::Request.new(http-version => '1.1', method => 'GET', target => '/inner-all');
    given $out.receive {
        isa-ok $_, Cro::HTTP::Response, 'Got a response';
        my $body = await .body-text;
        is-deeply $body, 'i1,i2,o1,o2', 'Outer configuration in included router handler available if requested';
    }

    $in.emit: Cro::HTTP::Request.new(http-version => '1.1', method => 'GET', target => '/outer-my');
    given $out.receive {
        isa-ok $_, Cro::HTTP::Response, 'Got a response';
        my $body = await .body-text;
        is-deeply $body, 'o1,o2', 'Inner route block configuration does not leak into outer local configuration';
    }

    $in.emit: Cro::HTTP::Request.new(http-version => '1.1', method => 'GET', target => '/outer-all');
    given $out.receive {
        isa-ok $_, Cro::HTTP::Response, 'Got a response';
        my $body = await .body-text;
        is-deeply $body, 'o1,o2', 'Inner route block configuration does not leak into outer configuration';
    }
}

done-testing;
