#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;
use Socket;
use IPC::Open3;
use Symbol qw(gensym);
use FritzUtil qw(http_get);

# Events: chan_msg, priv_msg
#   add_arm("net.pl", events => ['chan_msg', 'priv_msg']);
#
# .ping HOST         -- shells out to system ping, one packet, 2s timeout
# .dns HOST-or-IP    -- forward (A) and reverse (PTR) lookup
# .url URL           -- HTTP status line + content-type, no body

my $socket_path = "net-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

# Only ever pass strings matching this to an external process or DNS
# call -- refuses anything a shell/resolver could misinterpret.
my $HOST_RE = qr/^[A-Za-z0-9](?:[A-Za-z0-9\-]{0,62}\.)*[A-Za-z0-9\-]{1,63}$/;

sub safe_ping {
	my ($host) = @_;
	return undef unless $host =~ $HOST_RE;
	my ($in, $out, $err) = (undef, undef, gensym);
	my $pid = eval { open3($in, $out, $err, 'ping', '-c', '1', '-W', '2', '--', $host) };
	return undef unless $pid;
	close($in);
	local $/;
	my $stdout = <$out>;
	waitpid($pid, 0);
	return undef unless defined $stdout;
	if ($stdout =~ /time[=<]([\d.]+)\s*ms/) {
		return "$host is up, ${1}ms";
	} elsif ($stdout =~ /0 (?:packets )?received|100% packet loss/i) {
		return "$host: no reply (timeout/unreachable)";
	}
	return "$host: ping failed";
}

sub dns_lookup {
	my ($host) = @_;
	return undef unless $host =~ $HOST_RE || $host =~ /^[\d.]+$/ || $host =~ /^[0-9a-fA-F:]+$/;
	if ($host =~ /^[\d.]+$/) {
		my $packed = inet_aton($host);
		return "$host: invalid address" unless $packed;
		my $name = gethostbyaddr($packed, AF_INET);
		return $name ? "$host -> $name" : "$host -> (no PTR record)";
	}
	my $packed = inet_aton($host) or return "$host: could not resolve";
	return "$host -> " . inet_ntoa($packed);
}

while ($request->Accept() >= 0) {
	my $body = do { local $/; <STDIN> };
	my $chan = $ENV{CHANNEL} // '';
	chomp $body if defined $body;
	next unless defined $body;

	if ($body =~ /^\.ping\s+(\S+)/i) {
		my $r = safe_ping($1) // "invalid host.";
		print "$chan\n"; print "$r\n"; next;
	}

	if ($body =~ /^\.dns\s+(\S+)/i) {
		my $r = dns_lookup($1) // "invalid host.";
		print "$chan\n"; print "$r\n"; next;
	}

	if ($body =~ /^\.url\s+(\S+)/i) {
		my $url = $1;
		$url = "https://$url" unless $url =~ m{^https?://}i;
		my $r = http_get($url);
		print "$chan\n";
		if ($r->{success} || $r->{status} =~ /^\d+$/) {
			my $ct = $r->{headers}{'content-type'} // 'unknown';
			print "$url -> $r->{status} $r->{reason}, $ct\n";
		} else {
			print "$url -> fetch failed: $r->{content}\n";
		}
		next;
	}
}
