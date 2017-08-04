use Cro::HTTP::Response;
use Cro::Transform;

class Cro::HTTP::Log::File does Cro::Transform {
    has $.out = $*OUT;
    has $.err = $*ERR;

    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::HTTP::Response }

    method transformer(Supply $pipeline --> Supply) {
        supply {
            whenever $pipeline -> $resp {
                if $resp.status < 400 {
                    $!out.say: "[OK] {$resp.status} {$resp.request.target}";
                    emit $resp;
                } else {
                    $!err.say: "[ERROR] {$resp.status} {$resp.request.target}";
                }
            }
        }
    }
}
