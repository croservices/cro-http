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

role Cro::HTTP2::Frame {
    has int $.type;
    has int $.flags;
    has int $.stream-identifier;
}

class Cro::HTTP2::Frame::Data does Cro::HTTP2::Frame {
    has $.padding-length;
    has Blob $.data;

    method end-stream(--> Bool) { $!flags +& 0x1 != 0 }
    method padded(--> Bool) { $!flags +& 0x8 != 0 }

    method new(:$type = 0, :$flags, :$stream-identifier,
               :$padding-length, :$data) {
        self.bless(:$type, :$flags, :$stream-identifier,
                   :$padding-length, :$data);
    }
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

    method new(:$flags, :$stream-identifier,
               :$padding-length, :$exclusive,
               :$dependency, :$weight, :$headers) {
        self.bless(type => 1, :$flags, :$stream-identifier,
                   :$padding-length, :$exclusive,
               :$dependency, :$weight, :$headers);
    }
}

class Cro::HTTP2::Frame::Priority does Cro::HTTP2::Frame {
    has Bool $.exclusive;
    has UInt $.dependency;
    has UInt $.weight;

    method new(:$flags, :$stream-identifier,
               :$exclusive, :$dependency, :$weight) {
        self.bless(type => 2, :$flags, :$stream-identifier,
                   :$exclusive, :$dependency, :$weight);
    }
}

class Cro::HTTP2::Frame::RstStream does Cro::HTTP2::Frame {
    has ErrorCode $.error-code;

    method new(:$flags, :$stream-identifier,
               :$error-code) {
        self.bless(type => 3, :$flags, :$stream-identifier,
                   :$error-code);
    }
}

class Cro::HTTP2::Frame::Settings does Cro::HTTP2::Frame {
    has @.settings;

    method ack(--> Bool) { $!flags +& 0x1 != 0 }

    method new(:$flags, :$stream-identifier,
               :@settings) {
        self.bless(type => 4, :$flags, :$stream-identifier,
                   :@settings);
    }
}

class Cro::HTTP2::Frame::PushPromise does Cro::HTTP2::Frame {
    has $.padding-length;
    has UInt $.promised-sid;
    has Blob $.headers;

    method end-headers(--> Bool) { $!flags +& 0x4 != 0 }
    method padded(--> Bool) { $!flags +& 0x8 != 0 }

    method new(:$flags, :$stream-identifier,
               :$padding-length, :$promised-sid, :$headers) {
        self.bless(type => 5, :$flags, :$stream-identifier,
                   :$padding-length, :$promised-sid, :$headers);
    }
}

class Cro::HTTP2::Frame::Ping does Cro::HTTP2::Frame {
    has Blob $.payload;

    method ack(--> Bool) { $!flags +& 0x1 != 0 }

    method new(:$flags, :$stream-identifier,
               :$payload) {
        self.bless(type => 6, :$flags, :$stream-identifier,
                   :$payload);
    }
}

class Cro::HTTP2::Frame::Goaway does Cro::HTTP2::Frame {
    has UInt $.last-sid;
    has ErrorCode $.error-code;
    has Blob $.debug;

    method new(:$flags, :$stream-identifier,
               :$last-sid, :$error-code, :$debug) {
        self.bless(type => 7, :$flags, :$stream-identifier,
                   :$last-sid, :$error-code, :$debug);
    }
}

class Cro::HTTP2::Frame::WindowUpdate does Cro::HTTP2::Frame {
    has UInt $.increment;

    method new(:$flags, :$stream-identifier,
               :$increment) {
        self.bless(type => 8, :$flags, :$stream-identifier,
                   :$increment);
    }
}

class Cro::HTTP2::Frame::Continuation does Cro::HTTP2::Frame {
    has Blob $.headers;

    method end-headers(--> Bool) { $!flags +& 0x4 != 0 }

    method new(:$flags, :$stream-identifier,
               :$headers) {
        self.bless(type => 9, :$flags, :$stream-identifier,
                   :$headers);
    }
}

class Cro::HTTP2::Frame::Unknown does Cro::HTTP2::Frame {
    has Blob $.payload;
}
