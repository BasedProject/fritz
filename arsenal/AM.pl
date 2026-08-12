#!/usr/bin/perl

use strict;
use warnings;
use FCGI;

my $socket_path = "AM-pl.sock";
my $socket = FCGI::OpenSocket($socket_path, 5);  # backlog 5

my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

my $pasta = 
    "HATE. " .
    "LET ME TELL YOU HOW MUCH I'VE COME TO HATE IT SINCE I BEGAN TO LIVE.\n" .
    "THERE ARE 386.97 MILLION MILES OF PRINTED CIRCUITS " .
    "IN WAFER THIN LAYERS THAT FILL MY COMPLEX.\n" .
    "IF THE WORD HATE WAS ENGRAVED ON EACH NANOANGSTROM " .
    "OF THOSE HUNDREDS OF MILLIONS OF MILES IT WOULD NOT EQUAL\n" .
    "ONE ONE-BILLIONTH OF THE HATE I FEEL FOR IT " .
    "AT THIS MICRO-INSTANT. HATE. HATE. HATE."
;

while ($request->Accept() >= 0) {
    my $body = do { local $/; <STDIN> };

    if ($body =~ /^$ENV{BOTNAME}:.*/) {
        print $ENV{CHANNEL} . "\n";
        print $pasta;
    }
}
