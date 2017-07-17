enum Settings (:SETTINGS_HEADER_TABLE_SIZE(1) :SETTINGS_ENABLE_PUSH(2)
               :SETTINGS_MAX_CONCURRENT_STREAMS(3) :SETTINGS_INITIAL_WINDOW_SIZE(4)
               :SETTINGS_MAX_FRAME_SIZE(5) :SETTINGS_MAX_HEADER_LIST_SIZE(6));

enum ErrorCode <NO_ERROR PROTOCOL_ERROR
                INTERNAL_ERROR FLOW_CONTROL_ERROR
                SETTINGS_TIMEOUT STREAM_CLOSED
                FRAME_SIZE_ERROR REFUSED_STREAM
                CANCEL COMPRESSION_ERROR
                CONNECT_ERROR ENCHANCE_YOUR_CALM
                INADEQUATE_SECURITY HTTP_1_1_REQUIRED>;

class X::Cro::HTTP2::Error is Exception {
    has $.code;

    method message() { "$!code" }
}

role Cro::HTTP2::Frame {
    has Int $.type;
    has Int $.flags;
    has Int $.stream-identifier;
}

class Cro::HTTP2::Frame::Data does Cro::HTTP2::Frame {
    has UInt $.padding-length;
    has Blob $.data;

    method end-stream(--> Bool) { $!flags +& 0x1 != 0 }
    method padded(--> Bool) { $!flags +& 0x8 != 0 }

    submethod TWEAK() { $!type = 0; }
}

class Cro::HTTP2::Frame::Headers does Cro::HTTP2::Frame {
    has UInt $.padding-length;
    has Bool $.inclusive;
    has UInt $.dependency;
    has UInt $.weight;
    has Blob $.headers;

    method end-stream(--> Bool) { $!flags +& 0x1 != 0 }
    method end-headers(--> Bool) { $!flags +& 0x4 != 0 }
    method padded(--> Bool) { $!flags +& 0x8 != 0 }
    method priority(--> Bool) { $!flags +& 0x20 != 0 }

    submethod TWEAK() { $!type = 1; }
}

class Cro::HTTP2::Frame::Priority does Cro::HTTP2::Frame {
    has Bool $.exclusive;
    has UInt $.dependency;
    has UInt $.weight;

    submethod TWEAK() {
        $!type = 2;
        die X::Cro::HTTP2::Error.new(code => INTERNAL_ERROR) if $!flags != 0;
    }
}

class Cro::HTTP2::Frame::RstStream does Cro::HTTP2::Frame {
    has UInt $.error-code;

    submethod TWEAK() {
        $!type = 3;
        $!error-code = ErrorCode($!error-code) // INTERNAL_ERROR;
        die X::Cro::HTTP2::Error.new(code => INTERNAL_ERROR) if $!flags != 0;
    }
}

class Cro::HTTP2::Frame::Settings does Cro::HTTP2::Frame {
    has @.settings;

    method ack(--> Bool) { $!flags +& 0x1 != 0 }

    submethod TWEAK() { $!type = 4; }
}

class Cro::HTTP2::Frame::PushPromise does Cro::HTTP2::Frame {
    has UInt $.padding-length;
    has UInt $.promised-sid;
    has Blob $.headers;

    method end-headers(--> Bool) { $!flags +& 0x4 != 0 }
    method padded(--> Bool) { $!flags +& 0x8 != 0 }

    submethod TWEAK() { $!type = 5; }
}

class Cro::HTTP2::Frame::Ping does Cro::HTTP2::Frame {
    has Blob $.payload;

    method ack(--> Bool) { $!flags +& 0x1 != 0 }

    submethod TWEAK() {
        $!type = 6;
        if $!payload.elems < 8 {
            $!payload = $!payload ~ Blob.new((0x0 xx (8 - $!payload.elems)))
        } elsif $!payload.elems > 8 {
            die X::Cro::HTTP2::Error.new(code => INTERNAL_ERROR) if $!flags != 0;
        }
    }
}

class Cro::HTTP2::Frame::Goaway does Cro::HTTP2::Frame {
    has UInt $.last-sid;
    has UInt $.error-code;
    has Blob $.debug;

    submethod TWEAK() {
        $!type = 7;
        $!error-code = ErrorCode($!error-code) // INTERNAL_ERROR;
        die X::Cro::HTTP2::Error.new(code => INTERNAL_ERROR) if $!flags != 0;
    }
}

class Cro::HTTP2::Frame::WindowUpdate does Cro::HTTP2::Frame {
    has UInt $.increment;

    submethod TWEAK() {
        $!type = 8;
        die X::Cro::HTTP2::Error.new(code => INTERNAL_ERROR) if $!flags != 0;
    }
}

class Cro::HTTP2::Frame::Continuation does Cro::HTTP2::Frame {
    has Blob $.headers;

    method end-headers(--> Bool) { $!flags +& 0x4 != 0 }

    submethod TWEAK() { $!type = 9; }
}

class Cro::HTTP2::Frame::Unknown does Cro::HTTP2::Frame {
    has Blob $.payload;
}
