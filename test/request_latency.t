# Commands must answer promptly, in a long session and when each one gets its own session.
# Regression test for pawel-kow/epp#1, where about 40% of requests took 5 seconds.
# Credentials are the REG1_* defaults in docker-compose.yml.
use Time::HiRes qw(time);

my %login = (clid => 'foo', pw => 'bar');
my $requests = 25;
my $slow_after = 2;

my $domain_ns = 'xmlns:domain="urn:ietf:params:xml:ns:domain-1.0"';
my $check = qq{<check><domain:check $domain_ns><domain:name>absent-domain.example</domain:name></domain:check></check>};

sub report_slow {
	my ($name, @seconds) = @_;
	my @slow = grep { $_ > $slow_after } @seconds;
	printf("# %s: %d requests, slowest %.3fs\n", $name, scalar(@seconds), (sort { $b <=> $a } @seconds)[0]);
	is_code(scalar(@slow), 0, "$name: requests slower than ${slow_after}s");
}

# One session, as a client with a persistent connection
my $sock = epp_session(%login);
my @seconds;
for (1 .. $requests) {
	my $start = time();
	command_code($sock, $check);
	push(@seconds, time() - $start);
}
close($sock);
report_slow('one session', @seconds);

# A session per request, as a client without a connection pool
my %steps = (connect => [], login => [], command => [], logout => []);
sub timed {
	my ($step, $code) = @_;
	my $start = time();
	my $result = $code->();
	push(@{ $steps{$step} }, time() - $start);
	return $result;
}
for (1 .. $requests) {
	my $session = timed('connect', sub { epp_connect() });
	timed('login', sub { send_frame($session, login_frame(%login, cltrid => new_cltrid())); read_frame($session) });
	timed('command', sub { command_code($session, $check) });
	timed('logout', sub { command_code($session, '<logout/>') });
	close($session);
}
report_slow("session per request, $_", @{ $steps{$_} }) for (qw(connect login command logout));

done_testing();
