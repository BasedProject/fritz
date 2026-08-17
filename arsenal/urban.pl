#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;
use FritzUtil qw(http_get_json trunc);

# Events: chan_msg, priv_msg
#   add_arm("urban.pl", events => ['chan_msg', 'priv_msg']);
#
# .urban TERM -> top definition, one line

my $socket_path = "urban-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

sub uri_escape { my ($s) = @_; $s =~ s/([^A-Za-z0-9._~-])/sprintf('%%%02X', ord($1))/ge; return $s }

while ($request->Accept() >= 0) {
	my $body = do { local $/; <STDIN> };
	my $chan = $ENV{CHANNEL} // '';
	chomp $body if defined $body;
	next unless defined $body && $body =~ /^\.(?:ub|urban)\s+(.+)$/i;
	my $term = $1;

	my $data = http_get_json('https://api.urbandictionary.com/v0/define?term=' . uri_escape($term));
	my $def  = $data && $data->{list} && $data->{list}[0] ? $data->{list}[0]{definition} : undef;

	print "$chan\n";
	if ($def) {
		$def =~ s/[\[\]]//g;
		print trunc($def, 400) . "\n";
	} else {
		print "-- no definition found.\n";
	}
}
