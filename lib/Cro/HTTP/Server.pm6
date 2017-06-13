use Cro;
use Cro::HTTP::RequestParser;
use Cro::HTTP::ResponseSerializer;
use Cro::SSL;
use Cro::TCP;

class Cro::HTTP::Server does Cro::Service {
    only method new(Cro::Transform :$application!, :$host, :$port, :%ssl, :$before, :$after) {
        my $listener = %ssl
            ?? Cro::SSL::Listener.new(
                  |(:$host with $host),
                  |(:$port with $port),
                  |%ssl
               )
            !! Cro::TCP::Listener.new(
                  |(:$host with $host),
                  |(:$port with $port)
               );

        my @after = $after ~~ Iterable ?? $after.List !! ($after === Any ?? () !! $after);
        my @before = $before ~~ Iterable ?? $before.List !! ($before === Any ?? () !! $before);

        return Cro.compose(
            service-type => self.WHAT,
            $listener,
            Cro::HTTP::RequestParser.new,
            |@before,
            $application,
            |@after,
            Cro::HTTP::ResponseSerializer.new
        )
    }
}
