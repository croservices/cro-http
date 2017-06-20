# Here are placed all time-related things: regexes, hashes, grammars.

our %month-names = 1 => 'Jan', 2 => 'Feb', 3 => 'Mar',
                   4 => 'Apr', 5 => 'May', 6 => 'Jun',
                   7 => 'Jul', 8 => 'Aug', 9 => 'Sep',
                   10 => 'Oct', 11 => 'Nov', 12 => 'Dec';

our %amonth-names;
%month-names.antipairs.map({ %amonth-names{$_.key} = $_.value });

our %weekdays = 1 => 'Mon', 2 => 'Tue',
                3 => 'Wed', 4 => 'Thu',
                5 => 'Fri', 6 => 'Sat',
                7 => 'Sun';

our %aweekdays;
%weekdays.antipairs.map({ %aweekdays{$_.key} = $_.value });

my regex time { [\d\d ':'] ** 2 [\d\d] };
my regex wkday { 'Mon' | 'Tue' | 'Wed' | 'Thu' | 'Fri' | 'Sat' | 'Sun' };
my regex weekday { 'Monday' | 'Tuesday' | 'Wednesday' | 'Thursday' |
                   'Friday' | 'Saturday' | 'Sunday' };
my regex month { 'Jan' | 'Feb' | 'Mar' | 'Apr' | 'May' | 'Jun'
                 'Jul' | 'Aug' | 'Sep' | 'Oct' | 'Nov' | 'Dec' };

my regex date1 { (\d\d) ' ' <month>  ' ' (\d ** 4) };
my regex date2 { (\d\d) '-' <month>  '-' (\d ** 2) };
my regex date3 { <month> ' ' ([\d\d | ' ' \d]) };

my regex rfc1123-date { <wkday> ', ' <date1> ' ' <time> ' GMT' };
my regex rfc850-date { <weekday> ', ' <date2> ' ' <time> ' GMT' };
my regex asctime-date { <wkday> ' ' <date3> ' ' <time> ' ' (\d ** 4) };

our regex HTTP-date { <rfc1123-date> || <rfc850-date> || <asctime-date> };

grammar DateTimeGrammar {
    token TOP {^ <itime> $}
    proto rule itime              {*}
          rule itime:sym<rfc1123> { <rfc1123-date> }
          rule itime:sym<rfc850>  { <rfc850-date>  }
          rule itime:sym<asctime> { <asctime-date> }
}

class DateTimeActions {
    method TOP($/) {
        make $<itime>.made;
    }
    method itime:sym<rfc1123>($/) {
        my $time = $/<rfc1123-date><time>.split(':');
        my $date = $/<rfc1123-date><date1>;
        make DateTime.new(
            year    => (~$date[1]).Int,
            month   => %amonth-names{~$date<month>},
            day     => (~$date[0]).Int,
            hour    => (~$time[0]).Int,
            minute  => (~$time[1]).Int
        );
    }
    method itime:sym<rfc850>($/) {
        my $time = $/<rfc850-date><time>.split(':');
        my $date = $/<rfc850-date><date2>;
        make DateTime.new(
            year    => 70 <= (~$date[1]).Int <= 99 ?? (~$date[1]).Int + 1900 !! (~$date[1]).Int + 2000,
            month   => %amonth-names{~$date<month>},
            day     => (~$date[0]).Int,
            hour    => (~$time[0]).Int,
            minute  => (~$time[1]).Int
        );
    }
    method itime:sym<asctime>($/) {
        my $time = $/<asctime-date><time>.split(':');
        my $date = $/<asctime-date><date3>;
        make DateTime.new(
            year    => (~$/<asctime-date>[0]).Int,
            month   => %amonth-names{~$date<month>},
            day     => (~$date[0]).Int,
            hour    => (~$time[0]).Int,
            minute  => (~$time[1]).Int
        );
    }
}
