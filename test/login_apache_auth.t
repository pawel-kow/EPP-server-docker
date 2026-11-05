# Apache checks the password before session-login.cgi runs (EPPAuthURI). The script writes
# "-epp:login" into svTRID and the mod_epp error script does not, which shows who answered.
# Credentials are the REG1_* defaults in docker-compose.yml.

sub answered_by_login_script { return (($_[0] // '') =~ /-epp:login</) ? 1 : 0; }

my $valid = login_reply(clid => 'foo', pw => 'bar');
is_code(result_code($valid), 1000, 'valid login');
is_code(answered_by_login_script($valid), 1, 'valid login reaches the login script');

for my $case (
	['known clID, wrong password', clid => 'foo', pw => 'wrongpw'],
	['unknown clID',               clid => 'ghost', pw => 'nope'],
	['injection in clID',          clid => "foo'#", pw => 'wrongpw'],
) {
	my ($name, %login) = @$case;
	my $reply = login_reply(%login);
	is_code(result_code($reply), 2200, $name);
	is_code(answered_by_login_script($reply), 0, "$name stops at Apache");
}

done_testing();
