use Cro::HTTP::Request;

class Cro::HTTP::PushPromise is Cro::HTTP::Request {
    has $!response = Promise.new;

    method response(--> Promise) { $!response }

    method set-response($resp) {
        $!response.keep($resp);
    }

    method cancel-response() {
        $!response.break('Response cancelled');
    }
}
