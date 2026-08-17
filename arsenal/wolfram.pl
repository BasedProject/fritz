#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;
use FritzUtil qw(http_get trunc);

# Events: chan_msg, priv_msg
#   add_arm("wolfram.pl", events => ['chan_msg', 'priv_msg']);
#
# .wolfram QUERY -> WolframAlpha "Short Answers" API result
#
# REQUIRES an AppID: https://products.wolframalpha.com/api/ (free
# tier exists). Set FRITZ_WOLFRAM_APPID in the environment before
# starting this arm -- it refuses to run without one.

my $APPID = $ENV{FRITZ_WOLFRAM_APPID};

my $socket_path = "wolfram-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

sub uri_escape { my ($s) = @_; $s =~ s/([^A-Za-z0-9._~-])/sprintf('%%%02X', ord($1))/ge; return $s }

while ($request->Accept() >= 0) {
	my $body = do { local $/; <STDIN> };
	my $chan = $ENV{CHANNEL} // '';
	chomp $body if defined $body;
	next unless defined $body && $body =~ /^\.wolfram\s+(.+)$/i;
	my $q = $1;

	print "$chan\n";
	unless ($APPID) { print "-- FRITZ_WOLFRAM_APPID not configured.\n"; next }

	my $r = http_get('https://api.wolframalpha.com/v1/result?appid='
		. uri_escape($APPID) . '&i=' . uri_escape($q));
	if ($r->{success}) {
		print trunc($r->{content}, 400) . "\n";
	} elsif ($r->{status} == 501) {
		print "-- no short answer available.\n";
	} else {
		print "-- WolframAlpha lookup failed.\n";
	}
}
