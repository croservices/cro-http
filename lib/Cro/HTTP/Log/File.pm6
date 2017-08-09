use Cro::HTTP::Response;
use Cro::Transform;

class Cro::HTTP::Log::File does Cro::Transform {
    has IO::Handle $.logs;
    has IO::Handle $.errors;

    submethod BUILD(:$logs, :$errors) {
        with $logs {
            $!logs = $logs;
            with $errors { $!errors = $errors } else { $!errors = $logs }
        }
        else {
            $!logs = $*OUT;
            with $errors { $!errors = $errors } else { $!errors = $*ERR }
        }
    }

    method consumes() { Cro::HTTP::Response }
    method produces() { Cro::HTTP::Response }

    method transformer(Supply $pipeline --> Supply) {
        supply {
            whenever $pipeline -> $resp {
                if $resp.status < 400 {
                    $!logs.say: "[OK] {$resp.status} {$resp.request.target}";
                } else {
                    $!errors.say: "[ERROR] {$resp.status} {$resp.request.target}";
                }
                emit $resp;
            }
        }
    }
}
