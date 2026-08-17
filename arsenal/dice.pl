#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;
use FritzUtil qw(roll_dice);

# Events: chan_msg, priv_msg
#   add_arm("dice.pl", events => ['chan_msg', 'priv_msg']);
#
# .dice 2d20+5 / .dice 1d6 / .dice 1-100 / .dice =1d6
# aliases: .roll .rand .random
# .coin -> heads/tails

my $socket_path = "dice-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

while ($request->Accept() >= 0) {
	my $body = do { local $/; <STDIN> };
	my $chan = $ENV{CHANNEL} // '';
	chomp $body if defined $body;
	next unless defined $body;

	if ($body =~ /^\.coin\s*$/i) {
		print "$chan\n";
		print( (rand() < 0.5 ? "heads" : "tails") . "\n" );
		next;
	}

	next unless $body =~ /^\.(?:d|dice|roll|rand|random)\s+(\S+)\s*$/i;
	my $spec = $1;
	my ($result, $detail) = roll_dice($spec);
	print "$chan\n";
	print defined $result ? "$result $detail\n" : "-- bad dice spec: $spec\n";
}
