use Cro::HTTP::Log::File;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Test;

constant TEST_PORT = 31313;
my $url = "http://localhost:{TEST_PORT}";

my $app = route {
    get -> {
        content 'text/html', 'My response';
    }
    get -> 'route' {
        content 'text/plain', 'My response';
    }
    post -> 'route' {
        content 'text/plain', 'My response';
    }
    get -> 'error' {
        given response {
            $_.status = 500;
        }
    }
}

{
    my $out = open 'out'.IO, :w;
    my $err = open 'err'.IO, :w;

    use Cro::HTTP::Log::File;
    my $logger =  Cro::HTTP::Log::File.new(logs => $out, errors => $err);
    my $service = Cro::HTTP::Server.new(
        :host('localhost'), :port(TEST_PORT), application => $app,
        after => $logger
    );
    $service.start;

    my $completed = Promise.new;

    start {
        use Cro::HTTP::Client;
        await Cro::HTTP::Client.get("$url");
        await Cro::HTTP::Client.get("$url/route");
        await Cro::HTTP::Client.post("$url/route");
        await Cro::HTTP::Client.get("$url/error");
        CATCH {
            default {
                # The last await was thrown
                $completed.keep;
            }
        }
    }

    await Promise.anyof($completed, Promise.in(5));

    $out.close; $err.close;

    is (slurp 'out'), "[OK] 200 / - 127.0.0.1\n[OK] 200 /route - 127.0.0.1\n[OK] 200 /route - 127.0.0.1\n", 'Correct responses logged';
    is (slurp 'err'), "[ERROR] 500 /error - 127.0.0.1\n", 'Error responses logged';

    unlink 'out'.IO;
    unlink 'err'.IO;

    $service.stop();
}

done-testing;
