#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;
use Time::Piece;
use FritzUtil qw(read_lines write_lines);
use FritzAuth qw(is_authorized);

# Events: chan_msg, priv_msg, poll (interval e.g. 30s)
#   add_arm("alarm.pl", events => ['chan_msg', 'priv_msg', 'poll'], poll_interval => 30);
#
# .alarm DATE message...   -- schedule `message` to be posted back to
#                              this channel at DATE. DATE must be one
#                              of: "YYYY-MM-DD HH:MM", "YYYY-MM-DD",
#                              "YYYY-MM-DDTHH:MM" (all interpreted UTC).
# .alarmlist               -- authorized only; PMs the querier the
#                              pending alarms with their numbers.
# .alarmclear N             -- authorized only; cancels alarm number N
#                              (number as shown by .alarmlist).

my $store = $ENV{FRITZ_ALARM_FILE} || '/var/lib/fritz/alarm.store';
# line format: epoch\tchannel\tfrom\tmessage

my $socket_path = "alarm-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

sub load  { map { [ split /\t/, $_, 4 ] } read_lines($store) }
sub save  { write_lines($store, map { join("\t", @$_) } @_) }

sub parse_when {
	my ($s) = @_;
	for my $fmt ('%Y-%m-%dT%H:%M', '%Y-%m-%d %H:%M', '%Y-%m-%d') {
		my $t = eval { Time::Piece->strptime($s, $fmt) };
		return $t->epoch if $t;
	}
	return undef;
}

while ($request->Accept() >= 0) {
	my $body  = do { local $/; <STDIN> };
	my $event = $ENV{EVENT} // '';
	my $user  = $ENV{USERNAME} // '';
	my $chan  = $ENV{CHANNEL}  // '';
	chomp $body if defined $body;

	if ($event eq 'poll') {
		my @alarms = load();
		my $now = time();
		my (@due, @keep);
		for my $a (@alarms) { ($a->[0] <= $now ? push @due, $a : push @keep, $a) }
		save(@keep);
		next unless @due;
		# framework response is single-target; fire each due alarm as
		# its own response line-set to its own channel.
		for my $a (@due) {
			print "$a->[1]\n";
			print "alarm: $a->[3] (set by $a->[2])\n";
		}
		next;
	}

	next unless defined $body;

	if ($body =~ /^\.alarm\s+(\S+(?:[T ]\S+)?)\s+(.+)$/i) {
		my ($when_str, $msg) = ($1, $2);
		my $epoch = parse_when($when_str);
		unless ($epoch) {
			print "$chan\n"; print "-- bad date, use YYYY-MM-DD[THH:MM].\n"; next;
		}
		if ($epoch <= time()) {
			print "$chan\n"; print "-- that's in the past.\n"; next;
		}
		my @alarms = load();
		push @alarms, [$epoch, $chan, $user, $msg];
		save(@alarms);
		print "$chan\n";
		print "-- alarm set for $when_str UTC.\n";
		next;
	}

	if ($body =~ /^\.alarmlist\s*$/i) {
		unless (is_authorized($user)) { print "$chan\n"; print "-- not authorized.\n"; next }
		my @alarms = load();
		print "$user\n"; # PM the querier
		if (!@alarms) { print "-- no pending alarms.\n"; next }
		my $i = 0;
		for my $a (@alarms) {
			my $when = gmtime($a->[0])->strftime('%Y-%m-%d %H:%M');
			print(($i++) . ": $when UTC [$a->[1]] $a->[3] (by $a->[2])\n");
		}
		next;
	}

	if ($body =~ /^\.alarmclear\s+(\d+)\s*$/i) {
		unless (is_authorized($user)) { print "$chan\n"; print "-- not authorized.\n"; next }
		my $idx = $1;
		my @alarms = load();
		unless ($alarms[$idx]) { print "$chan\n"; print "-- no such alarm.\n"; next }
		splice(@alarms, $idx, 1);
		save(@alarms);
		print "$chan\n"; print "-- cleared alarm $idx.\n";
		next;
	}
}
