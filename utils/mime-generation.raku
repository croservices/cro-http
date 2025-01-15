my $fh = open :w, 'lib/Cro/HTTP/MimeTypes.pm6';
say $fh: "our %mime =";

my $count = 0;
for 'mime-types'.IO.lines {
    unless .starts-with('#') {
        if $_ ~~ /(<-[\t]>+) \t+ ((\w+)+ % ' ')/ {
            while $count < $1[0].elems {
                say $fh: "    '{$1[0][$count]}' => '$0',";
                $count++;
            }
            $count = 0;
        }
    }
}

$fh.print: ';'; # a trailing comma is valid

$fh.close;
