#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;
use FritzUtil qw(http_get_json decode_entities trunc);

# Events: chan_msg, priv_msg
#   add_arm("wiki.pl", events => ['chan_msg', 'priv_msg']);
#
# .wiki / .wikipedia / .w QUERY -> [URL] first-section extract, wrapped
# to fit a single IRC line regardless of accented/CJK characters in
# the extract (trunc() in FritzUtil is byte-budget aware, not
# character-count aware -- a flat 380-*character* cap could be well
# over 700 *bytes* for text with lots of accents, which is what was
# overrunning a single PRIVMSG and spilling onto a second line).

my $socket_path = "wiki-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

# Conservative single-line byte budget. Fritz's own privmsg() splitter
# has ~490 free bytes on a typical channel name at the IRC default
# 512-byte line length -- this stays comfortably under that with
# margin for a longer-than-usual channel name or shorter LINELEN from
# ISUPPORT, so this reply reliably lands as one line instead of
# depending on that splitter at all.
my $LINE_BUDGET = 400;
my $API   = 'https://en.wikipedia.org/w/api.php';

sub uri_escape { my ($s) = @_; $s =~ s/([^A-Za-z0-9._~-])/sprintf('%%%02X', ord($1))/ge; return $s }

sub wiki_lookup {
	my ($query) = @_;

	my $search_url = "$API?action=query&list=search&srsearch=" . uri_escape($query)
		. "&srlimit=1&format=json";
	my $sr = http_get_json($search_url);
	my $title = $sr && $sr->{query}{search}[0] ? $sr->{query}{search}[0]{title} : undef;
	return undef unless $title;

	my $extract_url = "$API?action=query&prop=extracts&exintro=1&explaintext=1"
		. "&titles=" . uri_escape($title) . "&format=json";
	my $er = http_get_json($extract_url);
	return undef unless $er;
	my ($page) = values %{ $er->{query}{pages} // {} };
	my $extract = $page ? $page->{extract} : undef;
	return undef unless $extract;

	$extract = decode_entities($extract);
	$extract =~ s/\s+/ /g;
	$extract =~ s/^\s+|\s+$//g;

	my $url = "https://en.wikipedia.org/wiki/" . uri_escape($title =~ s/ /_/gr);
	return ($url, $extract);
}

while ($request->Accept() >= 0) {
	my $body = do { local $/; <STDIN> };
	my $chan = $ENV{CHANNEL} // '';
	chomp $body if defined $body;
	next unless defined $body && $body =~ /^\.(?:wiki|wikipedia|w)\s+(.+)$/i;
	my $q = $1;

	my ($url, $extract) = wiki_lookup($q);
	print "$chan\n";
	if ($url) {
		my $prefix = "[$url] ";
		my $budget = $LINE_BUDGET - length($prefix);
		$budget = 60 if $budget < 60; # sane floor for pathological long URLs
		print $prefix . trunc($extract, $budget) . "\n";
	} else {
		print "-- no article found.\n";
	}
}
