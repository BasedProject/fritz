#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;

# Events: chan_msg
#   add_arm("bridge.pl", events => ['chan_msg'])
#
# Secondary bridge bot posts lines like:
#   rizon | e​bil > hello everyone
# i.e. "remote-network | remote-nick > message" -- two fields, not
# three. The bridge bot does NOT repeat its own name inside the
# message text; that's only ever the sender's real IRC nick, which we
# already have via $ENV{USERNAME} and check separately below. (An
# earlier version of this arm wrongly expected a leading
# "botname | " field inside the message body itself, which never
# matched real traffic -- the whole arm was a silent no-op.)
# A U+200B zero-width space is already inserted after the first
# character of the remote nick by the bridge, to stop it pinging any
# local user of the same name. This reformats the line into a normal
# local-looking chat line, stripping any existing ZWSP from the nick
# first and then re-inserting one fresh -- so the anti-ping property
# holds regardless of what the upstream bridge did.

my $socket_path = "bridge-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

my $ZWSP = "\x{200B}";

# Set this to the exact IRC nick the bridge bot itself connects as
# (e.g. FRITZ_BRIDGE_BOTNAME=chud), so we only ever reformat messages
# that actually came from it -- default is almost certainly wrong for
# your setup, it's just a placeholder.
my $BRIDGE_BOTNAME = $ENV{FRITZ_BRIDGE_BOTNAME} || 'bridgebot';

while ($request->Accept() >= 0) {
	my $body = do { local $/; <STDIN> };
	my $chan = $ENV{CHANNEL}  // '';
	my $user = $ENV{USERNAME} // '';
	chomp $body if defined $body;
	next unless defined $body;
	next unless lc($user) eq lc($BRIDGE_BOTNAME);

	next unless $body =~ /^\s*([^|]+?)\s*\|\s*(.+?)\s*>\s*(.*)$/;
	my ($remote_host, $remote_nick, $msg) = ($1, $2, $3);

	$remote_nick =~ s/$ZWSP//g;
	next unless length $remote_nick;
	my $safe_nick = length($remote_nick) > 1
		? substr($remote_nick, 0, 1) . $ZWSP . substr($remote_nick, 1)
		: $remote_nick;

	print "$chan\n";
	print "<$safe_nick\@$remote_host> $msg\n";
}
