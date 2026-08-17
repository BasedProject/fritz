package FritzAuth;

# Shared trust/authorization list. All arms that gate a command on
# authorization read the same flat file directly (arms are separate
# processes on the same host, so a shared file is the simplest correct
# IPC here). The auth.pl arm owns writes and is responsible for
# broadcasting "list updated" announcements to IRC; other arms only
# need is_authorized() to gate commands.
#
# File format: one nick per line, case-insensitive compare.

use strict;
use warnings;
use Fcntl qw(:flock);
use Exporter 'import';

our @EXPORT_OK = qw(is_authorized list_authorized add_authorized remove_authorized $AUTH_FILE);

our $AUTH_FILE = $ENV{FRITZ_AUTH_FILE} || '/var/www/fritz/auth.list';

sub list_authorized {
	return () unless -e $AUTH_FILE;
	open(my $fh, '<', $AUTH_FILE) or return ();
	flock($fh, LOCK_SH);
	chomp(my @lines = <$fh>);
	close($fh);
	return grep { length } @lines;
}

sub is_authorized {
	my ($nick) = @_;
	return 0 unless defined $nick && length $nick;
	for my $n (list_authorized()) {
		return 1 if lc($n) eq lc($nick);
	}
	return 0;
}

sub _write {
	my (@list) = @_;
	my $tmp = "$AUTH_FILE.tmp.$$";
	open(my $fh, '>', $tmp) or die "FritzAuth: $!";
	flock($fh, LOCK_EX);
	print $fh "$_\n" for @list;
	close($fh);
	rename($tmp, $AUTH_FILE) or die "FritzAuth rename: $!";
}

sub add_authorized {
	my ($nick) = @_;
	my @list = list_authorized();
	return 0 if grep { lc($_) eq lc($nick) } @list;
	push @list, $nick;
	_write(@list);
	return 1;
}

sub remove_authorized {
	my ($nick) = @_;
	my @list = list_authorized();
	my @new  = grep { lc($_) ne lc($nick) } @list;
	return 0 if @new == @list;
	_write(@new);
	return 1;
}

1;
