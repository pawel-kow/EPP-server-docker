# A clID is an XML token, so a registrar may have an apostrophe in it. Every script looks up
# REMOTE_USER in the registrar table, and that lookup must treat it as plain data.
# foo (REG1_* in docker-compose.yml) is the control: both registrars must get the same codes.

# DBI is not core Perl, but the CGI scripts need it, so the image always has it
use lib '/var/www/cgi-bin/epp/lib';
use DBI;
use Digest::SHA qw(sha1_base64);
use EPP::Config();

my %quoted = (clid => "o'brien", pw => 'quotedpw');

my %c = %EPP::Config::c;
my $dbh = DBI->connect("DBI:mysql:$c{mysql_database}:$c{mysql_host}:$c{mysql_port}",
	$c{mysql_username}, $c{mysql_password}, { RaiseError => 1 });
$dbh->do('INSERT IGNORE INTO `registrar` (`name`,`clid`,`pw`,`prefix`,`email`,`whois_server`,`url`,`abuse_email`,`abuse_phone`,`crdate`)'
	. " VALUES ('Quoted',?,?,'QT','quoted\@example.com','whois.quoted.example','https://quoted.example','abuse\@quoted.example','+12.3456789',NOW())",
	undef, $quoted{clid}, '{SHA}' . sha1_base64($quoted{pw}) . '=');

my $domain_ns = 'xmlns:domain="urn:ietf:params:xml:ns:domain-1.0"';
my $host_ns = 'xmlns:host="urn:ietf:params:xml:ns:host-1.0"';
my $absent = 'absent-domain.example';
my $host_seq = 0;

my %commands = (
	check    => sub { qq{<check><domain:check $domain_ns><domain:name>$absent</domain:name></domain:check></check>} },
	info     => sub { qq{<info><domain:info $domain_ns><domain:name>$absent</domain:name></domain:info></info>} },
	poll     => sub { qq{<poll op="req"/>} },
	transfer => sub { qq{<transfer op="query"><domain:transfer $domain_ns><domain:name>$absent</domain:name></domain:transfer></transfer>} },
	create   => sub { my $n = 'ns' . ++$host_seq . "-$$.outside.test"; qq{<create><host:create $host_ns><host:name>$n</host:name></host:create></create>} },
	delete   => sub { qq{<delete><domain:delete $domain_ns><domain:name>$absent</domain:name></domain:delete></delete>} },
	renew    => sub { qq{<renew><domain:renew $domain_ns><domain:name>$absent</domain:name><domain:curExpDate>2030-01-01</domain:curExpDate></domain:renew></renew>} },
	update   => sub { qq{<update><domain:update $domain_ns><domain:name>$absent</domain:name></domain:update></update>} },
	logout   => sub { qq{<logout/>} },
);

for my $name (sort keys %commands) {
	my $control = epp_session(clid => 'foo', pw => 'bar');
	my $want = command_code($control, $commands{$name}->());
	close($control);

	my $sock = epp_session(%quoted);
	is_code(command_code($sock, $commands{$name}->()), $want // 'a reply from the control', "$name as $quoted{clid}");
	close($sock);
}

done_testing();
