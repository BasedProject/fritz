package FritzUtil;

use strict;
use warnings;
use HTTP::Tiny;
use Fcntl qw(:flock);
use Exporter 'import';

our @EXPORT_OK = qw(
	http_get http_get_json html_title decode_entities trunc
	read_lines write_lines append_line
	parse_dice roll_dice
);

# ---- HTTP ----

sub ua {
	return HTTP::Tiny->new(
		agent      => 'Fritz-IRC-bot/1.0 (+irc-arm)',
		timeout    => 8,
		verify_SSL => 1,
		max_size   => 512 * 1024,
	);
}

sub http_get {
	my ($url, %opt) = @_;
	return ua()->get($url, \%opt);
}

sub http_get_json {
	my ($url, %opt) = @_;
	require JSON::PP;
	my $r = http_get($url, %opt);
	return undef unless $r->{success};
	my $data = eval { JSON::PP::decode_json($r->{content}) };
	return $data;
}

# minimal entity decode -- avoids depending on HTML::Entities
sub decode_entities {
	my ($s) = @_;
	return $s unless defined $s;
	my %named = (amp => '&', lt => '<', gt => '>', quot => '"', apos => "'", nbsp => ' ');
	$s =~ s{&(\#x?[0-9a-fA-F]+|[a-zA-Z]+);}{
		my $e = $1;
		if    ($e =~ m{^\#x([0-9a-fA-F]+)$}) { chr(hex($1)) }
		elsif ($e =~ m{^\#(\d+)$})           { chr($1) }
		elsif (exists $named{$e})            { $named{$e} }
		else                                  { "&$e;" }
	}ge;
	return $s;
}

sub html_title {
	my ($url) = @_;
	my $r = http_get($url);
	return undef unless $r->{success};
	my $ct = $r->{headers}{'content-type'} // '';
	return undef unless $ct =~ m{text/html}i;
	return undef unless $r->{content} =~ /<title[^>]*>(.*?)<\/title>/is;
	my $t = decode_entities($1);
	$t =~ s/\s+/ /g;
	$t =~ s/^\s+|\s+$//g;
	return length($t) ? $t : undef;
}

sub trunc {
	my ($s, $max) = @_;
	$s =~ s/\s+/ /g;
	return $s if length($s) <= $max;
	my $cut = substr($s, 0, $max - 1);
	$cut =~ s/\s+\S*$//;
	$cut = substr($s, 0, $max - 1) unless length($cut);
	return "$cut\x{2026}";
}

# ---- flat-file storage, flock'd ----

sub read_lines {
	my ($path) = @_;
	return () unless -e $path;
	open(my $fh, '<', $path) or return ();
	flock($fh, LOCK_SH);
	chomp(my @lines = <$fh>);
	close($fh);
	return @lines;
}

sub write_lines {
	my ($path, @lines) = @_;
	my $tmp = "$path.tmp.$$";
	open(my $fh, '>', $tmp) or die "write_lines: $!";
	flock($fh, LOCK_EX);
	print $fh "$_\n" for @lines;
	close($fh);
	rename($tmp, $path) or die "write_lines rename: $!";
	return 1;
}

sub append_line {
	my ($path, $line) = @_;
	open(my $fh, '>>', $path) or die "append_line: $!";
	flock($fh, LOCK_EX);
	print $fh "$line\n";
	close($fh);
	return 1;
}

# ---- dice ----
# supports: NdM, NdM+K, NdM-K, A-B (random range), leading '=' ignored
sub parse_dice {
	my ($spec) = @_;
	$spec =~ s/^=//;
	$spec =~ s/\s+//g;
	if ($spec =~ /^(\d*)d(\d+)([+-]\d+)?$/i) {
		my $n    = $1 eq '' ? 1 : $1;
		my $die  = $2;
		my $mod  = $3 // 0;
		return (n => $n, die => $die, mod => $mod, type => 'dice');
	}
	if ($spec =~ /^(-?\d+)-(-?\d+)$/) {
		return (lo => $1, hi => $2, type => 'range');
	}
	return ();
}

sub roll_dice {
	my ($spec) = @_;
	my %p = parse_dice($spec);
	return undef unless %p;
	if ($p{type} eq 'dice') {
		return undef if $p{n} < 1 || $p{n} > 100 || $p{die} < 1 || $p{die} > 100000;
		my @rolls = map { 1 + int(rand($p{die})) } 1 .. $p{n};
		my $sum = $p{mod};
		$sum += $_ for @rolls;
		my $detail = '[' . join(',', @rolls) . ']';
		$detail .= sprintf('%+d', $p{mod}) if $p{mod};
		return ($sum, $detail);
	} else {
		my ($lo, $hi) = ($p{lo}, $p{hi});
		($lo, $hi) = ($hi, $lo) if $lo > $hi;
		my $r = $lo + int(rand($hi - $lo + 1));
		return ($r, "[$lo-$hi]");
	}
}

1;
