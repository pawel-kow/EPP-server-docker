# Every CGI run and Apache's DBD pool look up the database host, so a slow lookup delays a
# request by the same amount. Regression test for pawel-kow/epp#1.
use POSIX ();
use Socket qw(getaddrinfo AF_UNSPEC SOCK_STREAM);
use Time::HiRes qw(time);

my $lookups = 40;
my $slow_after = 1;

# One process per lookup, as with CGI: after a timeout glibc stops sending A and AAAA in
# parallel for the rest of the process, so a loop in one process would stall only once
sub lookup_seconds {
	pipe(my $reader, my $writer) or die "pipe: $!\n";
	my $pid = fork() // die "fork: $!\n";
	if (!$pid) {
		my $start = time();
		# The same query libmariadb makes: AF_UNSPEC asks for A and AAAA
		my ($err) = getaddrinfo('mariadb', 3306, { family => AF_UNSPEC, socktype => SOCK_STREAM });
		print {$writer} ($err ? 'failed' : time() - $start);
		close($writer);
		POSIX::_exit(0);
	}
	close($writer);
	my $took = <$reader>;
	waitpid($pid, 0);
	return $took;
}

my ($slow, $worst, $failures) = (0, 0, 0);
for (1 .. $lookups) {
	my $took = lookup_seconds();
	if ($took eq 'failed') {
		$failures++;
		next;
	}
	$slow++ if $took > $slow_after;
	$worst = $took if $took > $worst;
}
printf("# %d lookups, slowest %.3fs\n", $lookups, $worst);
is_code($failures, 0, 'lookups of the database host that failed');
is_code($slow, 0, "lookups of the database host slower than ${slow_after}s");

done_testing();
