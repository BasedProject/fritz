#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;
use IPC::Open3;
use Symbol qw(gensym);
use FritzUtil qw(trunc);

# Events: chan_msg, priv_msg
#   add_arm("yt.pl", events => ['chan_msg', 'priv_msg']);
#
# .yt QUERY -> first video's title and URL
#
# Uses yt-dlp for search (no API key needed, `emerge net-misc/yt-dlp`
# or pip install). If you'd rather use the official YouTube Data API,
# swap search_first() for an http_get to
# https://www.googleapis.com/youtube/v3/search with your key.

my $socket_path = "yt-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

sub search_first {
	my ($query) = @_;
	my ($in, $out, $err) = (undef, undef, gensym);
	my $pid = eval {
		open3($in, $out, $err, 'yt-dlp',
			"ytsearch1:$query",
			'--print', '%(title)s\t%(webpage_url)s',
			'--no-warnings', '--skip-download', '--quiet');
	};
	return undef unless $pid;
	close($in);
	local $/;
	my $line = <$out>;
	waitpid($pid, 0);
	return undef unless defined $line;
	chomp $line;
	my ($title, $url) = split /\t/, $line, 2;
	return undef unless $title && $url;
	return ($title, $url);
}

while ($request->Accept() >= 0) {
	my $body = do { local $/; <STDIN> };
	my $chan = $ENV{CHANNEL} // '';
	chomp $body if defined $body;
	next unless defined $body && $body =~ /^\.yt\s+(.+)$/i;
	my $q = $1;

	my ($title, $url) = search_first($q);
	print "$chan\n";
	print $title ? trunc($title, 200) . " - $url\n" : "-- no results.\n";
}
