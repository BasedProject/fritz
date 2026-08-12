#!/usr/bin/perl

use strict;
use warnings;
use FCGI;

my $socket_path = "ascii-pl.sock";
my $socket = FCGI::OpenSocket($socket_path, 5);  # backlog 5

my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

while ($request->Accept() >= 0) {
    my $body = do { local $/; <STDIN> };

    if ($body =~ /^.ascii\s*(.*)/) {
        my $text = $1;

        chomp $text;
        if ($text eq '') {
            $text = "[ASCII] Usage: .ascii <text>";
            goto end;
        }

        if (length $text > 15) {
            $text = "[ASCII] Input too long (max 15 chars)";
            goto end;
        }

        open my $fh, '-|', 'figlet', '-f', 'Small', '-d', 'arsenal/', $text
            or die "figlet: $!";
        $text = do { local $/; <$fh> };
        close $fh;

      end:
        print $ENV{CHANNEL} . "\n";
        print $text;
    }
}
