#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;
use FritzAuth qw(is_authorized list_authorized add_authorized remove_authorized);

# Events: register this arm for 'join' and 'chan_msg' and 'priv_msg'.
#   add_arm("auth.pl", events => ['join', 'chan_msg', 'priv_msg']);
#
# - On the bot's own join, announces the current trust list to that
#   channel ("this is who we respect").
# - .trust / .trust list      -> show list (anyone)
# - .trust add NICK           -> add (authorized only)
# - .trust del NICK           -> remove (authorized only)
#   both broadcast "trust list updated" back to the channel/PM the
#   command was issued from.

my $socket_path = "auth-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

sub trust_line {
	# my @l = list_authorized();
	# return @l ? "Trusted: " . join(', ', @l) : "Trusted: (nobody yet)";
}

while ($request->Accept() >= 0) {
	my $body  = do { local $/; <STDIN> };
	my $event = $ENV{EVENT} // '';
	my $user  = $ENV{USERNAME} // '';
	my $chan  = $ENV{CHANNEL}  // '';

	if ($event eq 'join') {
		if ($user eq ($ENV{BOTNAME} // '')) {
			print "$chan\n";
			print "-- " . trust_line() . "\n";
		}
		next;
	}

	chomp $body if defined $body;
	next unless defined $body && $body =~ /^\.trust\b\s*(.*)$/i;
	my $arg = $1 // '';

	if ($arg eq '' || $arg =~ /^list$/i) {
		print "$chan\n";
		print trust_line() . "\n";
		next;
	}

	if ($arg =~ /^add\s+(\S+)$/i) {
		my $target = $1;
		unless (is_authorized($user)) {
			print "$chan\n"; print "-- not authorized.\n"; next;
		}
		my $added = add_authorized($target);
		print "$chan\n";
		print $added ? "-- trust list updated: added $target. " . trust_line() . "\n"
		             : "-- $target already trusted.\n";
		next;
	}

	if ($arg =~ /^(?:del|remove)\s+(\S+)$/i) {
		my $target = $1;
		unless (is_authorized($user)) {
			print "$chan\n"; print "-- not authorized.\n"; next;
		}
		my $removed = remove_authorized($target);
		print "$chan\n";
		print $removed ? "-- trust list updated: removed $target. " . trust_line() . "\n"
		               : "-- $target wasn't trusted.\n";
		next;
	}

	print "$chan\n";
	print "-- usage: .trust [list|add NICK|del NICK]\n";
}
