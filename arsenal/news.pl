#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;
use FritzUtil qw(http_get trunc read_lines write_lines);
use FritzAuth qw(is_authorized);

# Events: chan_msg, priv_msg, poll (interval e.g. 300s)
#   add_arm("news.pl", events => ['chan_msg', 'priv_msg', 'poll'], poll_interval => 300);
#
# .news              -- PM the querier the last few posted entries
# .newslist           -- PM the querier the tracked feed list
# .newsadd URL       -- track a feed (authorized only)
# .newsdel N         -- stop tracking feed #N from .newslist (authorized only)
#
# On poll: fetches each feed, compares the newest entry link against
# the last-seen link on file, and posts anything new (newest-first,
# capped) to FRITZ_NEWS_CHANNEL (or the first channel in JOINED if
# unset) -- and appends what it posted to a small history log that
# .news reads from.

my $feeds_file   = $ENV{FRITZ_NEWS_FEEDS}   || '/var/www/fritz/news.feeds';
my $history_file = $ENV{FRITZ_NEWS_HISTORY} || '/var/www/fritz/news.history';
# feeds line format:   url\tlast_seen_link
# history line format: epoch\ttitle\tlink
my $POST_CAP    = 5;   # new entries posted per feed per poll
my $HISTORY_CAP = 200; # entries kept on disk
my $NEWS_SHOW   = 10;  # entries shown by .news

my $socket_path = "news-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

sub load_feeds { map { [ split /\t/, $_, 2 ] } read_lines($feeds_file) }
sub save_feeds  { write_lines($feeds_file, map { join("\t", @$_) } @_) }

sub append_history {
	my (@items) = @_; # {title, link}
	return unless @items;
	my @hist = map { [ split /\t/, $_, 3 ] } read_lines($history_file);
	push @hist, [time(), $_->{title}, $_->{link}] for @items;
	splice(@hist, 0, @hist - $HISTORY_CAP) if @hist > $HISTORY_CAP;
	write_lines($history_file, map { join("\t", @$_) } @hist);
}

# returns list of {title, link} newest-first; tries XML::LibXML if
# present, otherwise falls back to a small regex scraper.
sub parse_feed {
	my ($xml) = @_;
	if (eval { require XML::LibXML; 1 }) {
		my @items;
		my $doc = eval { XML::LibXML->load_xml(string => $xml) } or return ();
		for my $node ($doc->findnodes('//*[local-name()="item"] | //*[local-name()="entry"]')) {
			my ($title) = $node->findnodes('.//*[local-name()="title"]');
			my $link;
			for my $l ($node->findnodes('.//*[local-name()="link"]')) {
				my $href = $l->getAttribute('href');
				$link = $href ? $href : $l->textContent;
				last if $link;
			}
			next unless $link;
			push @items, { title => $title ? $title->textContent : $link, link => $link };
		}
		return @items;
	}
	# fallback regex scraper (RSS <item> or Atom <entry> blocks)
	my @items;
	while ($xml =~ m{<(?:item|entry)\b.*?>(.*?)</(?:item|entry)>}gis) {
		my $block = $1;
		my ($title) = $block =~ m{<title[^>]*>(.*?)</title>}is;
		my ($link)  = $block =~ m{<link[^>]*href="([^"]+)"} or ();
		unless ($link) { ($link) = $block =~ m{<link[^>]*>(.*?)</link>}is }
		next unless $link;
		$title = 'untitled' unless defined $title;
		$title =~ s/<!\[CDATA\[(.*?)\]\]>/$1/gs;
		$title =~ s/<[^>]+>//g;
		$link  =~ s/\s+//g;
		push @items, { title => $title, link => $link };
	}
	return @items;
}

sub news_target {
	return $ENV{FRITZ_NEWS_CHANNEL} if $ENV{FRITZ_NEWS_CHANNEL};
	my @joined = split /:/, ($ENV{JOINED} // '');
	return $joined[0];
}

while ($request->Accept() >= 0) {
	my $body  = do { local $/; <STDIN> };
	my $event = $ENV{EVENT} // '';
	my $user  = $ENV{USERNAME} // '';
	my $chan  = $ENV{CHANNEL}  // '';
	chomp $body if defined $body;

	if ($event eq 'poll') {
		my @feeds = load_feeds();
		next unless @feeds;
		my $target = news_target();
		next unless $target;
		my @out;
		for my $f (@feeds) {
			my ($url, $last_seen) = @$f;
			my $r = http_get($url);
			next unless $r->{success};
			my @items = parse_feed($r->{content});
			next unless @items;
			my @fresh;
			for my $it (@items) {
				last if $last_seen && $it->{link} eq $last_seen;
				push @fresh, $it;
			}
			@fresh = $items[0] ? ($items[0]) : () unless $last_seen; # first run: seed quietly, don't dump whole feed
			if (@fresh) {
				$f->[1] = $items[0]{link};
				push @out, @fresh[0 .. ($#fresh < $POST_CAP - 1 ? $#fresh : $POST_CAP - 1)];
			}
		}
		save_feeds(@feeds);
		next unless @out;
		append_history(@out);
		print "$target\n";
		print "News: " . trunc($_->{title}, 200) . " - $_->{link}\n" for @out;
		next;
	}

	next unless defined $body;

	if ($body =~ /^\.news\s*$/i) {
		my @hist = map { [ split /\t/, $_, 3 ] } read_lines($history_file);
		print "$user\n"; # PM the querier
		if (!@hist) { print "-- no news posted yet.\n"; next }
		my @recent = @hist[ (@hist > $NEWS_SHOW ? @hist - $NEWS_SHOW : 0) .. $#hist ];
		for my $h (reverse @recent) {
			my ($ts, $title, $link) = @$h;
			my @t = gmtime($ts);
			my $when = sprintf('%04d-%02d-%02d %02d:%02dZ', $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1]);
			print "$when " . trunc($title, 200) . " - $link\n";
		}
		next;
	}

	if ($body =~ /^\.newslist\s*$/i) {
		my @feeds = load_feeds();
		print "$user\n"; # PM the querier
		if (!@feeds) { print "-- no feeds tracked.\n"; next }
		my $i = 0;
		print(($i++) . ": $_->[0]\n") for @feeds;
		next;
	}

	if ($body =~ /^\.newsadd\s+(\S+)\s*$/i) {
		unless (is_authorized($user)) { print "$chan\n"; print "-- not authorized.\n"; next }
		my $url = $1;
		my @feeds = load_feeds();
		if (grep { $_->[0] eq $url } @feeds) { print "$chan\n"; print "-- already tracked.\n"; next }
		push @feeds, [$url, ''];
		save_feeds(@feeds);
		print "$chan\n"; print "-- tracking $url\n";
		next;
	}

	if ($body =~ /^\.newsdel\s+(\d+)\s*$/i) {
		unless (is_authorized($user)) { print "$chan\n"; print "-- not authorized.\n"; next }
		my $idx = $1;
		my @feeds = load_feeds();
		unless ($feeds[$idx]) { print "$chan\n"; print "-- no such feed.\n"; next }
		my $removed = splice(@feeds, $idx, 1);
		save_feeds(@feeds);
		print "$chan\n"; print "-- untracked $removed->[0]\n";
		next;
	}
}
