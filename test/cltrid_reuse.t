# A reused clTRID must get an EPP error, on every command. Regression test for pawel-kow/epp#16.
# Credentials are the REG1_* defaults in docker-compose.yml.

my %login = (clid => 'foo', pw => 'bar');

my $domain_ns = 'xmlns:domain="urn:ietf:params:xml:ns:domain-1.0"';
my $host_ns = 'xmlns:host="urn:ietf:params:xml:ns:host-1.0"';
my $absent = 'absent-domain.example';
my $check = qq{<check><domain:check $domain_ns><domain:name>$absent</domain:name></domain:check></check>};
my $new_host = "ns-$$.outside.test";

my %commands = (
	check    => $check,
	info     => qq{<info><domain:info $domain_ns><domain:name>$absent</domain:name></domain:info></info>},
	poll     => qq{<poll op="req"/>},
	transfer => qq{<transfer op="query"><domain:transfer $domain_ns><domain:name>$absent</domain:name></domain:transfer></transfer>},
	create   => qq{<create><host:create $host_ns><host:name>$new_host</host:name></host:create></create>},
	delete   => qq{<delete><domain:delete $domain_ns><domain:name>$absent</domain:name></domain:delete></delete>},
	renew    => qq{<renew><domain:renew $domain_ns><domain:name>$absent</domain:name><domain:curExpDate>2030-01-01</domain:curExpDate></domain:renew></renew>},
	update   => qq{<update><domain:update $domain_ns><domain:name>$absent</domain:name></domain:update></update>},
	logout   => qq{<logout/>},
);

for my $name (sort keys %commands) {
	my $cltrid = new_cltrid();

	my $first = epp_session(%login);
	command_reply($first, $commands{$name}, $cltrid);
	close($first);

	my $sock = epp_session(%login);
	my $reply = command_reply($sock, $commands{$name}, $cltrid);
	is_code(result_code($reply), 2400, "$name: reused clTRID");
	is_code(($reply // '') =~ m{<clTRID>\Q$cltrid\E</clTRID>} ? 1 : 0, 1, "$name: reply echoes the clTRID");
	is_code(($reply // '') =~ m{<svTRID>[^<]+</svTRID>} ? 1 : 0, 1, "$name: reply has a svTRID");
	is_code(($reply // '') =~ /clTRID already used/ ? 1 : 0, 1, "$name: reply names the cause");
	# mod_epp ends the session on any logout, whatever the script answers
	my $after = $name eq 'logout' ? 2002 : 1000;
	is_code(command_code($sock, $check), $after, "$name: session state afterwards");
	close($sock);
}

# The same clTRID, reused on a different command than the one that first took it
my $cltrid = new_cltrid();
my $sock = epp_session(%login);
is_code(command_code($sock, $check, $cltrid), 1000, 'first use of a clTRID');
is_code(command_code($sock, $commands{poll}, $cltrid), 2400, 'clTRID reused on another command');
close($sock);

# clTRID is optional in EPP, so leaving it out is not reuse
$sock = epp_session(%login);
is_code(result_code(command_reply_without_cltrid($sock, $check)), 1000, "command without a clTRID, try $_") for (1, 2);
close($sock);

# clTRIDs are unique per registrar, so another registrar may use the same value
my %other = (clid => 'baz', pw => 'qux');
$cltrid = new_cltrid();
$sock = epp_session(%login);
is_code(command_code($sock, $check, $cltrid), 1000, 'clTRID used by the first registrar');
close($sock);
$sock = epp_session(%other);
is_code(command_code($sock, $check, $cltrid), 1000, 'same clTRID used by a second registrar');
is_code(command_code($sock, $check, $cltrid), 2400, 'second registrar reuses its own clTRID');
close($sock);

$cltrid = new_cltrid();
is_code(login_code(%login, cltrid => $cltrid), 1000, 'login clTRID used by the first registrar');
is_code(login_code(%other, cltrid => $cltrid), 1000, 'same login clTRID used by a second registrar');

# 64 characters is the longest clTRID EPP allows, and the column is no wider: the stored
# form must still tell apart values that differ only in the last character
my $long = substr(new_cltrid() . ('x' x 64), 0, 63);
$sock = epp_session(%login);
is_code(command_code($sock, $check, "${long}a"), 1000, 'clTRID of the maximum length');
is_code(command_code($sock, $check, "${long}b"), 1000, 'another one, differing in the last character');
is_code(command_code($sock, $check, "${long}a"), 2400, 'reused clTRID of the maximum length');
close($sock);

done_testing();
