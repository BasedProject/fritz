#!/usr/bin/perl

use strict;
use warnings;
use FCGI;

my $socket_path = "ascii-pl.sock";
my $socket = FCGI::OpenSocket($socket_path, 5);  # backlog 5

my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);
my $length_limit = 15;
my $desired_width = 9*$length_limit;

while ($request->Accept() >= 0) {
    my $body = do { local $/; <STDIN> };

    if ($body =~ /^.ascii\s*(.*)/) {
        my $text = $1;

        chomp $text;
        if ($text eq '') {
            $text = "[ASCII] Usage: .ascii <text>";
            goto end;
        }

        if (length $text > $length_limit) {
            #$text = "[ASCII] Input too long (max " . $length_limit . " chars)";
            #goto end;
            $text = substr($text, 0, $length_limit);
        }

        open my $fh, '-|', 'figlet', '-f', 'Small', '-d', 'arsenal/', '-w', $desired_width, '--', $text
            or die "figlet: $!";
        $text = do { local $/; <$fh> };
        close $fh;

      end:
        print $ENV{CHANNEL} . "\n";
        print $text;
    }
}
