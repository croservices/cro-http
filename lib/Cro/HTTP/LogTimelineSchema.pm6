use Log::Timeline;

class Cro::HTTP::LogTimeline::Serve
        does Log::Timeline::Task['Cro', 'HTTP Server', 'Process Request'] {}
class Cro::HTTP::LogTimeline::Route
        does Log::Timeline::Task['Cro', 'HTTP Server', 'Route'] {}
class Cro::HTTP::LogTimeline::Handle
        does Log::Timeline::Task['Cro', 'HTTP Server', 'Run Handler'] {}
class Cro::HTTP::LogTimeline::ResponseBody
        does Log::Timeline::Task['Cro', 'HTTP Server', 'Send Response Body'] {}
