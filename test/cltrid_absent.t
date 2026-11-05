# clTRID is optional in EPP, and the schema requires at least 3 characters when it is present.
# A reply to a frame without one must therefore leave the element out, not send it empty or
# make a value up. Credentials are the REG1_* defaults in docker-compose.yml.

my %login = (clid => 'foo', pw => 'bar');
my $domain_ns = 'xmlns:domain="urn:ietf:params:xml:ns:domain-1.0"';
my $check = qq{<check><domain:check $domain_ns><domain:name>absent-domain.example</domain:name></domain:check></check>};

sub no_cltrid_in {
	my ($reply, $want_code, $name) = @_;
	is_code(result_code($reply), $want_code, "$name: result code");
	is_code(($reply // '<clTRID>') =~ /<clTRID/ ? 1 : 0, 0, "$name: no clTRID element");
	is_code(($reply // '') =~ m{<svTRID>[^<]+</svTRID>} ? 1 : 0, 1, "$name: has a svTRID");
}

# Replies from session-login.cgi
my $sock = epp_connect();
my $frame = login_frame(%login, cltrid => 'REMOVED');
$frame =~ s{<clTRID>REMOVED</clTRID>}{};
send_frame($sock, $frame);
no_cltrid_in(read_frame($sock), 1000, 'login');

# Replies from the command scripts, including a failure
no_cltrid_in(command_reply_without_cltrid($sock, $check), 1000, 'check');
no_cltrid_in(command_reply_without_cltrid($sock,
	qq{<info><domain:info $domain_ns><domain:name>absent-domain.example</domain:name></domain:info></info>}),
	2303, 'failing info');

# Reply from session-logout.cgi
no_cltrid_in(command_reply_without_cltrid($sock, '<logout/>'), 1500, 'logout');
close($sock);

# Reply from error-authrequired.cgi
$sock = epp_connect();
no_cltrid_in(command_reply_without_cltrid($sock, $check), 2002, 'command before login');
close($sock);

# Reply from the schema or parse error script
$sock = epp_connect();
send_frame($sock, '<?xml version="1.0" encoding="UTF-8"?><epp xmlns="urn:ietf:params:xml:ns:epp-1.0"><command>');
my $reply = read_frame($sock);
close($sock);
is_code(($reply // '') =~ m{<clTRID>\s*</clTRID>|non-specified} ? 1 : 0, 0, 'malformed frame: no empty or made-up clTRID');
is_code(defined($reply) ? 1 : 0, 1, 'malformed frame: gets a reply');

# A client may send the value the scripts used as a placeholder, and gets it back
$sock = epp_session(%login);
my $echo = command_reply($sock, $check, 'not-given');
close($sock);
is_code(($echo // '') =~ m{<clTRID>not-given</clTRID>} ? 1 : 0, 1, 'clTRID "not-given" is echoed');

done_testing();
