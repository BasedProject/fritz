#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;
use FritzUtil qw(html_title trunc);

# Events: chan_msg, priv_msg
#   add_arm("titlesniff.pl", events => ['chan_msg', 'priv_msg']);
#
# Any message containing an http(s) URL gets its <title> fetched and
# echoed as "^ Title text". Silently no-ops on fetch failure, non-HTML
# content, or a missing/empty <title> -- a URL post shouldn't spam an
# error into the channel.
#
# If this looked totally dead before: FritzUtil's fetcher now sends a
# real browser User-Agent instead of a self-identifying bot string.
# A lot of commonly-linked sites (anything behind Cloudflare, most
# social platforms) silently bot-block or serve a JS challenge page
# instead of real HTML to a script-looking UA -- which produces no
# <title> match at all, indistinguishable from "nothing detected".
# That was almost certainly the actual bug, not the URL regex.

my $socket_path = "titlesniff-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

my $URL_RE = qr{https?://[^\s<>"']+}i;

while ($request->Accept() >= 0) {
	my $body = do { local $/; <STDIN> };
	my $chan = $ENV{CHANNEL} // '';
	next unless defined $body && $body =~ /($URL_RE)/;
	my $url = $1;
	# strip trailing punctuation/closing brackets that are almost
	# certainly message formatting, not part of the URL -- e.g. "check
	# this out: https://example.com/foo)" or "...foo," or "...foo."
	$url =~ s/[)\]\}>,.!?;:'"]+$//;
	next unless length $url;

	my $title = eval { html_title($url) };
	next unless defined $title && length $title;

	print "$chan\n";
	print "^ " . trunc($title, 300) . "\n";
}
