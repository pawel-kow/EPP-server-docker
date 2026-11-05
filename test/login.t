# EPP login. Regression test for pawel-kow/epp#14.
# Credentials are the REG1_* defaults in docker-compose.yml.

my %valid = (clid => 'foo', pw => 'bar');

is_code(login_code(%valid), 1000, 'valid login');

is_code(login_code(clid => 'foo', pw => 'wrongpw'), 2200, 'known clID, wrong password');

is_code(login_code(clid => 'ghost', pw => 'nope'), 2200, 'unknown clID');

is_code(
	login_code(%valid, objuris => ['urn:ietf:params:xml:ns:domain-1.0']),
	1000,
	'valid login with only the domain objURI',
);

my $cltrid = new_cltrid();
is_code(login_code(%valid, cltrid => $cltrid), 1000, 'first use of a clTRID');
is_code(login_code(%valid, cltrid => $cltrid), 2400, 'reused clTRID');

done_testing();
