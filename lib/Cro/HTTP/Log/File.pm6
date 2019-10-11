use Cro::HTTP::Response;
use Cro::Transform;

class Cro::HTTP::Log::File does Cro::Transform {
    has IO::Handle $.logs;
    has IO::Handle $.errors;
    has Bool $.flush;

    submethod BUILD(:$logs, :$errors, :$!flush = True) {
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
                    $!logs.say: "[OK] {$resp.status} {$resp.request.original-target} - {$resp.request.connection.peer-host}";
                    $!logs.flush if $!flush;
                } else {
                    $!errors.say: "[ERROR] {$resp.status} {$resp.request.original-target} - {$resp.request.connection.peer-host}";
                    $!errors.flush if $!flush;
                }
                emit $resp;
            }
        }
    }
}
