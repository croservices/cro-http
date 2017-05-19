use Cro;
use Cro::HTTP::RequestParser;
use Cro::HTTP::ResponseSerializer;
use Cro::SSL;
use Cro::TCP;

class Cro::HTTP::Server does Cro::Service {
    only method new(Cro::Transform :$application!, :$host, :$port, :%ssl) {
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

        return Cro.compose(
            service-type => self.WHAT,
            $listener,
            Cro::HTTP::RequestParser.new,
            $application,
            Cro::HTTP::ResponseSerializer.new
        )
    }
}
