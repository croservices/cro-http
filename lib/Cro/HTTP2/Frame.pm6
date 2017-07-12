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
    has UInt $.padding-length;
    has Blob $.data;

    method end-stream(--> Bool) { $!flags +& 0x1 }
    method padded(--> Bool) { $!flags +& 0x8 }
}

class Cro::HTTP2::Frame::Headers does Cro::HTTP2::Frame {
    has UInt $.padding-length;
    has Bool $.inclusive;
    has UInt $.dependency;
    has UInt $.weight;
    has Blob $.headers;

    method end-stream(--> Bool) { $!flags +& 0x1 }
    method end-headers(--> Bool) { $!flags +& 0x4 }
    method padded(--> Bool) { $!flags +& 0x8 }
    method priority(--> Bool) { $!flags +& 0x20 }
}

class Cro::HTTP2::Frame::Priority does Cro::HTTP2::Frame {
    has UInt $.exclusive;
    has UInt $.dependency;
    has UInt $.weight;
}

class Cro::HTTP2::Frame::RstStream does Cro::HTTP2::Frame {
    has ErrorCode $.error-code;
}

class Cro::HTTP2::Frame::Settings does Cro::HTTP2::Frame {
    has @.settings;

    method ack(--> Bool) { $!flags +& 0x1 }
}

class Cro::HTTP2::Frame::PushPromise does Cro::HTTP2::Frame {
    has UInt $.padding-length;
    has UInt $.promised-sid;
    has Blob $.headers;

    method end-headers(--> Bool) { $!flags +& 0x4 }
    method padded(--> Bool) { $!flags +& 0x8 }
}

class Cro::HTTP2::Frame::Ping does Cro::HTTP2::Frame {
    has Blob $.payload;

    method ack(--> Bool) { $!flags +& 0x1 }
}

class Cro::HTTP2::Frame::Goaway does Cro::HTTP2::Frame {
    has UInt $.last-sid;
    has ErrorCode $.error-code;
    has Blob $.debug;
}

class Cro::HTTP2::Frame::WindowUpdate does Cro::HTTP2::Frame {
    has UInt $.increment;
}


class Cro::HTTP2::Frame::Continuation does Cro::HTTP2::Frame {
    has Blob $.headers;

    method end-headers(--> Bool) { $!flags +& 0x4 }
}

class Cro::HTTP2::Frame::Unknown does Cro::HTTP2::Frame {
    has Blob $.payload;
}
