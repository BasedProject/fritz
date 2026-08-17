#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;

# Events: chan_msg, priv_msg
#   add_arm("pick.pl", events => ['chan_msg', 'priv_msg']);
#
# .pick opt1 opt2 opt3 ... -> picks one at random
#
# The IRC event framework here doesn't expose a channel member list
# (JOINED is only channels the bot itself is in), so there's no
# "pick a random person in the room" without an explicit list --
# this always requires the options spelled out.

my $socket_path = "pick-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

while ($request->Accept() >= 0) {
	my $body = do { local $/; <STDIN> };
	my $chan = $ENV{CHANNEL} // '';
	chomp $body if defined $body;
	next unless defined $body && $body =~ /^\.pick\s*(.*)$/i;
	my @opts = split /\s+/, ($1 // '');
	@opts = grep { length } @opts;

	print "$chan\n";
	if (@opts < 2) {
		print "-- usage: .pick option1 option2 [...]\n";
	} else {
		print $opts[int(rand(scalar @opts))] . "\n";
	}
}
