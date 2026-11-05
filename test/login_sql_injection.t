# SQL injection through clID at login. Regression test for pawel-kow/epp#15.
# The client controls clID before it is authenticated, so none of these may log in.
# Credentials are the REG1_* defaults in docker-compose.yml.

my @attacks = (
	["foo'#",                 'comment out the password check'],
	["foo' -- x",             'comment out the password check, dash form'],
	["x' OR '1'='1",          'always-true clause, stops before the password check'],
	["x' OR 1=1#",            'log in without knowing any clID'],
	["x' UNION SELECT id FROM registrar#", 'take the registrar id from a UNION'],
);

for my $attack (@attacks) {
	my ($clid, $what) = @$attack;
	is_code(login_code(clid => $clid, pw => 'wrongpw'), 2200, "$what: $clid");
}

is_code(login_code(clid => "o'brien", pw => 'nope'), 2200, 'quote in an unknown clID is plain data');

# The lookups still have to find a real registrar
is_code(login_code(clid => 'foo', pw => 'bar'), 1000, 'valid login still works');

done_testing();
