#!/usr/bin/perl
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use FCGI;
use FritzUtil qw(http_get_json);

# Events: chan_msg, priv_msg
#   add_arm("crypto.pl", events => ['chan_msg', 'priv_msg']);
#
# .bitcoin -> USD price, and how many Whoppers stacked to that height
# .monero  -> USD price, and how many McChickens stacked to that height
#
# Burger price/height are rough estimates (comments below) -- this is
# a novelty command, not a price feed.

my $socket_path = "crypto-pl.sock";
my $socket  = FCGI::OpenSocket($socket_path, 5);
my $request = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

my %COIN = (
	bitcoin => { id => 'bitcoin', burger => 'Whopper',   price => 6.99, height_m => 0.10 },
	monero  => { id => 'monero',  burger => 'McChicken', price => 4.29, height_m => 0.05 },
);

sub coin_report {
	my ($key) = @_;
	my $c = $COIN{$key};
	my $data = http_get_json("https://api.coingecko.com/api/v3/simple/price?ids=$c->{id}&vs_currencies=usd");
	my $price = $data && $data->{ $c->{id} } ? $data->{ $c->{id} }{usd} : undef;
	return undef unless defined $price;

	my $count  = $price / $c->{price};
	my $height = $count * $c->{height_m};
	return sprintf(
		'$%s USD = %s %ss stacked = %sm tall',
		commify($price), commify(int($count)), $c->{burger}, commify(sprintf('%.1f', $height))
	);
}

sub commify {
	my ($n) = @_;
	my ($int, $frac) = split /\./, $n;
	1 while $int =~ s/(\d)(\d{3})(?!\d)/$1,$2/;
	return defined $frac ? "$int.$frac" : $int;
}

while ($request->Accept() >= 0) {
	my $body = do { local $/; <STDIN> };
	my $chan = $ENV{CHANNEL} // '';
	chomp $body if defined $body;
	next unless defined $body && $body =~ /^\.(bitcoin|monero)\s*$/i;
	my $key = lc($1);

	my $r = coin_report($key);
	print "$chan\n";
	print $r ? "$r\n" : "-- price lookup failed.\n";
}
