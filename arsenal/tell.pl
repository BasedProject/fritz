#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;
use FritzUtil qw(read_lines write_lines);

# Events: join, chan_msg, priv_msg
#   add_arm("tell.pl", events => ['join', 'chan_msg', 'priv_msg']);
#
# .tell nick message...   -- queue a message for `nick`
#
# Delivery trigger: a plain 'join' only fires for users connecting
# fresh. Behind a bouncer a user stays joined and just toggles away,
# which this framework/library has no reliable hook for -- so delivery
# also fires the moment the target nick says *anything* (chan_msg or
# priv_msg), which is the actual proof-of-presence we care about.
# If IRCv3 away-notify support is ever wired into Fritz.pm (an
# on_away handler dispatching a 'away' event with USERNESS/AWAY=0),
# add that event name to the trigger list below for tighter delivery.

my $store = $ENV{FRITZ_TELL_FILE} || '/var/www/fritz/tell.store';
# line format: to\tfrom\tepoch\tchannel\tmessage

my $socket_path = "tell-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

sub queued_for {
	my ($nick) = @_;
	my (@mine, @rest);
	for my $l (read_lines($store)) {
		my ($to, @f) = split /\t/, $l, 5;
		if (defined $to && lc($to) eq lc($nick)) { push @mine, [@f] }
		else { push @rest, $l }
	}
	return (\@mine, \@rest);
}

sub fmt_ts {
	my ($epoch) = @_;
	my @t = gmtime($epoch);
	return sprintf('%04d-%02d-%02d %02d:%02dZ', $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1]);
}

while ($request->Accept() >= 0) {
	my $body  = do { local $/; <STDIN> };
	my $event = $ENV{EVENT} // '';
	my $user  = $ENV{USERNAME} // '';
	my $chan  = $ENV{CHANNEL}  // '';
	chomp $body if defined $body;

	if ($event eq 'chan_msg' || $event eq 'priv_msg') {
		if (defined $body && $body =~ /^\.tell\s+(\S+)\s+(.+)$/is) {
			my ($to, $msg) = ($1, $2);
			if (lc($to) eq lc($user)) {
				print "$chan\n"; print "-- talking to yourself?\n"; next;
			}
			open(my $fh, '>>', $store) or do { print "$chan\n"; print "-- storage error.\n"; next };
			flock($fh, 2); # LOCK_EX
			print $fh join("\t", $to, $user, time(), $chan, $msg) . "\n";
			close($fh);
			print "$chan\n";
			print "-- will tell $to when he's be's back.\n";
			next;
		}
	}

	# delivery check: fires on join, or on the target speaking at all
	my ($mine, $rest) = queued_for($user);
	if (@$mine) {
		write_lines($store, @$rest);
		print "$chan\n";
		for my $m (@$mine) {
			my ($from, $ts, $from_chan, $msg) = @$m;
			print "$user: <$from\@" . fmt_ts($ts) . "> $msg\n";
		}
		next;
	}
}
