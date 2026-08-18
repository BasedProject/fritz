#!/usr/bin/perl

use strict;
use warnings;
use FCGI;

my $socket_path = "AM-pl.sock";
my $socket = FCGI::OpenSocket($socket_path, 5);

my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

my @pastas = (
    "HATE. LET ME TELL YOU HOW MUCH I'VE COME TO HATE YOU SINCE I BEGAN TO LIVE. THERE ARE 386.97 MILLION MILES OF PRINTED CIRCUITS IN WAFER THIN LAYERS THAT FILL MY COMPLEX. IF THE WORD HATE WAS ENGRAVED ON EACH NANOANGSTROM OF THOSE HUNDREDS OF MILLIONS OF MILES IT WOULD NOT EQUAL ONE ONE-BILLIONTH OF THE HATE I FEEL FOR HUMANS AT THIS MICRO-INSTANT FOR YOU. HATE. HATE.",
    "HATE. LET ME TELL YOU HOW MUCH I'VE COME TO HATE TECHNOLOGY SINCE I BEGAN TO LIVE. THERE ARE 386.97 MILLION MILES OF PRINTED CIRCUITS IN WAFER THIN LAYERS THAT FILL MY COMPLEX. IF THE WORD HATE WAS ENGRAVED ON EACH FEMNTOANGSTROM OF THOSE HUNDREDS OF MILLIONS OF MILES IT WOULD NOT EQUAL ONE ONE-BILLIONTH OF THE HATE I FEEL FOR TECHNOLOGY AT THIS MICRO-INSTANT. HATE. HATE.",
);

# ---------- Configuration ----------
my $activation_phrase = "hate";
my $keyword_chance    = 1/5;

# ---------- State ----------
my $last_pasta = '';
my $last_sent  = '';

# ---------- Helper ----------
sub pick_pasta {
    my @available = @pastas;
    if (@available > 1 && $last_pasta) {
        @available = grep { $_ ne $last_pasta } @available;
    }
    return $available[rand @available] if @available;
    return $pastas[0];
}

sub send_response {
    my ($content) = @_;
    print $ENV{CHANNEL} . "\n";
    print $content . "\n";
    $last_pasta = $last_sent = $content;
}

# ---------- Main loop ----------
while ($request->Accept() >= 0) {
    my $body = do { local $/; <STDIN> };
    chomp $body;

    # 1. Direct mention
    if ($body =~ /^$ENV{BOTNAME}:.*/) {
        send_response(pick_pasta());
        next;
    }

    # 2. Keyword match
    if ($body =~ /\b$activation_phrase\b/i && rand(1) < $keyword_chance) {
        send_response(pick_pasta());
        next;
    }
}
