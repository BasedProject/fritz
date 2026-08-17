#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;
use JSON::PP;
use FritzUtil qw(http_get);

# Events: chan_msg, priv_msg
#   add_arm("whois.pl", events => ['chan_msg', 'priv_msg']);
#
# .whois / .rdap TARGET -> RDAP query via rdap.org's bootstrap
# redirector (handles domains, IPs and ASNs), result written as
# pretty-printed JSON to RDAP_DIR/TARGET.rdap and served from
# BASE_URL -- configure both for your nginx vhost.

my $RDAP_DIR  = $ENV{FRITZ_RDAP_DIR}  || '/var/www/fritz/rdap';
my $BASE_URL  = $ENV{FRITZ_RDAP_URL}  || 'https://who.chud.cyou';

my $socket_path = "whois-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

# keep filenames boring and safe
my $TARGET_RE = qr/^[A-Za-z0-9](?:[A-Za-z0-9.\-:]{0,250})[A-Za-z0-9]$/;

sub rdap_lookup {
	my ($target) = @_;
	return undef unless $target =~ $TARGET_RE;
	my $kind = $target =~ /^[\d.]+$/ || $target =~ /^[0-9a-fA-F:]+$/ ? 'ip' : 'domain';
	my $r = http_get("https://rdap.org/$kind/$target");
	return undef unless $r->{success};
	my $data = eval { decode_json($r->{content}) };
	return undef unless $data;
	return $data;
}

sub safe_filename {
	my ($target) = @_;
	(my $f = $target) =~ s/[^A-Za-z0-9.\-]/_/g;
	return "$f";
}

while ($request->Accept() >= 0) {
	my $body = do { local $/; <STDIN> };
	my $chan = $ENV{CHANNEL} // '';
	chomp $body if defined $body;
	next unless defined $body && $body =~ /^\.(?:whois|rdap)\s+(\S+)\s*$/i;
	my $target = $1;

	my $data = rdap_lookup($target);
	print "$chan\n";
	unless ($data) { print "-- RDAP lookup failed for $target.\n"; next }

	my $fname = safe_filename($target);
	my $path  = "$RDAP_DIR/$fname";
	if (open(my $fh, '>', $path)) {
		print $fh JSON::PP->new->pretty->canonical->encode($data);
		close($fh);
		print "$BASE_URL/$fname\n";
	} else {
		print "-- fetched RDAP data but couldn't write $path: $!\n";
	}
}
