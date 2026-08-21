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
#
# Chanop commands -- authorized only, chan_msg only (a PM has no real
# channel to act on: $chan there is just the sender's own nick, used
# only as a reply target). Ban masks are always NICK!*@* -- Fritz has
# no visibility into hostmasks from the event data, only nicks.
#   .kick    NICK [reason]
#   .invite  NICK
#   .ban     NICK [reason]         -> +b NICK!*@*, then kicks
#   .unban   NICK                  -> -b NICK!*@*
#   .voice   NICK / .devoice NICK
#   .hop     NICK / .dehop   NICK  (halfop -- needs ircd support for +h)
#   .op      NICK / .deop    NICK
#
# None of these can see whether the bot actually holds the ops needed
# to carry them out -- fritz.py doesn't currently wire numeric errors
# (e.g. 482 ERR_CHANOPRIVSNEEDED) back to arms, so a rejected MODE/KICK
# fails silently from here. Worth knowing if a command appears to do
# nothing.

my $socket_path = "auth-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

sub trust_line {
	my @l = list_authorized();
	return @l ? "Trusted: " . join(', ', @l) : "Trusted: (nobody yet)";
}

# .cmd NICK -> MODE $chan <+|-><mode_char> NICK
my %MODE_CMDS = (
	voice   => ['v', 1],
	devoice => ['v', 0],
	hop     => ['h', 1],
	dehop   => ['h', 0],
	op      => ['o', 1],
	deop    => ['o', 0],
);

while ($request->Accept() >= 0) {
	my $body  = do { local $/; <STDIN> };
	my $event = $ENV{EVENT} // '';
	my $user  = $ENV{USERNAME} // '';
	my $chan  = $ENV{CHANNEL}  // '';

	chomp $body if defined $body;
	next unless defined $body && length $body;

	if ($body =~ /^\.trust\b\s*(.*)$/i) {
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
		next;
	}

	# Everything from here acts on the actual channel.
	next unless $event eq 'chan_msg';

	if ($body =~ /^\.kick\s+(\S+)(?:\s+(.*))?$/i) {
		my ($target, $reason) = ($1, $2 // 'kicked');
		unless (is_authorized($user)) {
			print "$chan\n"; print "-- not authorized.\n"; next;
		}
		print "!raw\n";
		print "KICK $chan $target :$reason\n";
		next;
	}

	if ($body =~ /^\.invite\s+(\S+)$/i) {
		my $target = $1;
		unless (is_authorized($user)) {
			print "$chan\n"; print "-- not authorized.\n"; next;
		}
		print "!raw\n";
		print "INVITE $target $chan\n";
		next;
	}

	if ($body =~ /^\.ban\s+(\S+)(?:\s+(.*))?$/i) {
		my ($target, $reason) = ($1, $2 // 'banned');
		unless (is_authorized($user)) {
			print "$chan\n"; print "-- not authorized.\n"; next;
		}
		print "!raw\n";
		print "MODE $chan +b $target!*\@*\n";
		print "KICK $chan $target :$reason\n";
		next;
	}

	if ($body =~ /^\.unban\s+(\S+)$/i) {
		my $target = $1;
		unless (is_authorized($user)) {
			print "$chan\n"; print "-- not authorized.\n"; next;
		}
		print "!raw\n";
		print "MODE $chan -b $target!*\@*\n";
		next;
	}

	if ($body =~ /^\.(voice|devoice|hop|dehop|op|deop)\s+(\S+)$/i) {
		my ($cmd, $target) = (lc $1, $2);
		unless (is_authorized($user)) {
			print "$chan\n"; print "-- not authorized.\n"; next;
		}
		my ($mode_char, $set) = @{ $MODE_CMDS{$cmd} };
		print "!raw\n";
		print "MODE $chan " . ($set ? '+' : '-') . "$mode_char $target\n";
		next;
	}
}
