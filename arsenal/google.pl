#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;
use FritzUtil qw(http_get decode_entities trunc);

# Events: chan_msg, priv_msg
#   add_arm("google.pl", events => ['chan_msg', 'priv_msg']);
#
# .google QUERY -> first result title + URL
#
# Google's own Custom Search JSON API needs a key + a CSE id
# (developers.google.com/custom-search/v1/introduction). Without one
# on hand, this scrapes DuckDuckGo's no-JS HTML endpoint instead,
# which needs no key. If you get a Google CSE key later, swap
# first_result() for an http_get_json to
# https://www.googleapis.com/customsearch/v1?key=...&cx=...&q=....

my $socket_path = "google-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

sub uri_escape { my ($s) = @_; $s =~ s/([^A-Za-z0-9._~-])/sprintf('%%%02X', ord($1))/ge; return $s }

sub first_result {
	my ($query) = @_;
	my $r = http_get('https://html.duckduckgo.com/html/?q=' . uri_escape($query));
	return undef unless $r->{success};
	return undef unless $r->{content} =~
		m{class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>}is;
	my ($url, $title) = ($1, $2);
	$title =~ s/<[^>]+>//g;
	$title = decode_entities($title);
	# DDG wraps redirect links as //duckduckgo.com/l/?uddg=<encoded target>
	if ($url =~ /uddg=([^&]+)/) {
		$url = $1;
		$url =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
	}
	return ($title, $url);
}

while ($request->Accept() >= 0) {
	my $body = do { local $/; <STDIN> };
	my $chan = $ENV{CHANNEL} // '';
	chomp $body if defined $body;
	next unless defined $body && $body =~ /^\.(?:g|google|bing|ddg|duck)\s+(.+)$/i;
	my $q = $1;

	my ($title, $url) = first_result($q);
	print "$chan\n";
	print $title ? trunc($title, 200) . " - $url\n" : "-- no results.\n";
}
