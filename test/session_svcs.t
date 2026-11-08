# RFC 5730 section 2.9.3.1: the <svcs> a client sends in <login> select the services of the
# session. The server ignored them, so secDNS:infData, idn:data, rgp:infData and identExt:infData
# appeared in every reply whether the client had chosen that extension or not (pawel-kow/epp#27).
# Credentials are the REG1_* defaults in docker-compose.yml.

use lib '/var/www/cgi-bin/epp/lib';
use DBI;
use EPP::Config();

my %c = %EPP::Config::c;
my $dbh = DBI->connect("DBI:mysql:$c{mysql_database}:$c{mysql_host}:$c{mysql_port}",
	$c{mysql_username}, $c{mysql_password}, { RaiseError => 1 });

my $domain_ns = 'xmlns:domain="urn:ietf:params:xml:ns:domain-1.0"';
my $contact_ns = 'xmlns:contact="urn:ietf:params:xml:ns:contact-1.0"';
my $secdns_uri = 'urn:ietf:params:xml:ns:secDNS-1.1';
my $idn_uri = 'urn:ietf:params:xml:ns:idn-1.0';
my $rgp_uri = 'urn:ietf:params:xml:ns:rgp-1.0';
my $ident_uri = 'http://www.nic.xx/XXNIC-EPP/identExt-1.0';
my @all = ($rgp_uri, $secdns_uri, $idn_uri, $ident_uri);

my ($tld) = $dbh->selectrow_array('SELECT `tld` FROM `domain_tld` LIMIT 1');
$tld =~ s/^\.//;
$tld = lc($tld);

# An extURI the server does not know. It marks this run's rows in epp_session.
my $marker = "urn:example:session-svcs-$$-" . time();

my $name = "xn--tst-qla.$tld"; # täst
my $sha256 = 'E2D3C916F6DEEAC73294E8268FB5885044A833FC5459588F4A9184CFC41A5766';
my $contact = sprintf('FO-s%d', $$);

sub info_domain { return command_reply($_[0], qq{<info><domain:info $domain_ns><domain:name>$name</domain:name></domain:info></info>}) // ''; }
sub info_contact { return command_reply($_[0], qq{<info><contact:info $contact_ns><contact:id>$contact</contact:id></contact:info></info>}) // ''; }

# The top-level extension elements in a reply, sorted, or "(none)"
sub extensions {
	my ($reply) = @_;
	return 'no reply' unless length $reply;
	return result_code($reply) unless result_code($reply) eq '1000';
	return '(none)' unless $reply =~ m{<extension>(.*?)</extension>}s;
	my $ext = $1;
	# Only the top-level elements, which declare their namespace; not their children
	my @found = sort ($ext =~ m{<((?:rgp|secDNS|idn|identExt):\w+)\s+xmlns:}g);
	return @found ? join(' ', @found) : 'empty <extension>';
}

sub login { my (@uris) = @_; return epp_session(clid => 'foo', pw => 'bar', exturis => [@uris]); }

sub session_rows {
	my ($uri) = @_;
	my ($n) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM `epp_session` WHERE CONCAT(' ', `exturis`, ' ') LIKE ?}, undef, "% $uri %");
	return $n;
}

# Seed: a domain with DS data and IDN data, and a contact, made in a session that chose everything
my $setup = login(@all);
command_code($setup, qq{<delete><domain:delete $domain_ns><domain:name>$name</domain:name></domain:delete></delete>});
is_code(command_code($setup, qq{<create><domain:create $domain_ns><domain:name>$name</domain:name>}
	. q{<domain:period unit="y">1</domain:period><domain:authInfo><domain:pw>Secret123</domain:pw></domain:authInfo>}
	. q{</domain:create></create><extension>}
	. qq{<secDNS:create xmlns:secDNS="$secdns_uri"><secDNS:dsData><secDNS:keyTag>12345</secDNS:keyTag><secDNS:alg>13</secDNS:alg>}
	. qq{<secDNS:digestType>2</secDNS:digestType><secDNS:digest>$sha256</secDNS:digest></secDNS:dsData></secDNS:create>}
	. qq{<idn:data xmlns:idn="$idn_uri"><idn:table>de</idn:table></idn:data></extension>}), 1000, 'create a domain with DS and IDN data');
is_code(command_code($setup, qq{<create><contact:create $contact_ns><contact:id>$contact</contact:id>}
	. q{<contact:postalInfo type="int"><contact:name>Session Test</contact:name><contact:addr><contact:street>Street 1</contact:street>}
	. q{<contact:city>Berlin</contact:city><contact:pc>10115</contact:pc><contact:cc>DE</contact:cc></contact:addr></contact:postalInfo>}
	. q{<contact:voice>+49.301234567</contact:voice><contact:email>session@example.com</contact:email>}
	. q{<contact:authInfo><contact:pw>Sw0rd-fish!Xy</contact:pw></contact:authInfo></contact:create></create>}), 1000, 'create a contact');
is_code(extensions(info_domain($setup)), 'idn:data rgp:infData secDNS:infData', 'all extURIs chosen: domain:info carries every extension');
is_code(extensions(info_contact($setup)), 'identExt:infData', 'all extURIs chosen: contact:info carries identExt');
close($setup);

# Each extension appears only when its extURI was chosen
my $none = login();
is_code(extensions(info_domain($none)), '(none)', 'no extURI chosen: domain:info has no <extension>');
is_code(extensions(info_contact($none)), '(none)', 'no extURI chosen: contact:info has no <extension>');
close($none);

my $secdns = login($secdns_uri);
is_code(extensions(info_domain($secdns)), 'secDNS:infData', 'secDNS-1.1 only');
close($secdns);

my $idn = login($idn_uri);
is_code(extensions(info_domain($idn)), 'idn:data', 'idn-1.0 only');
close($idn);

my $rgp = login($rgp_uri, $ident_uri);
is_code(extensions(info_domain($rgp)), 'rgp:infData', 'rgp-1.0 and identExt: domain:info');
is_code(extensions(info_contact($rgp)), 'identExt:infData', 'rgp-1.0 and identExt: contact:info');
close($rgp);

# The choice is stored at login and removed at logout
my $sock = login($secdns_uri, $marker);
is_code(session_rows($marker), 1, 'login stores the session row');
is_code(extensions(info_domain($sock)), 'secDNS:infData', 'first login on the connection: secDNS-1.1');
is_code(command_code($sock, '<logout/>'), 1500, 'logout');
is_code(session_rows($marker), 0, 'logout removes the session row');

# mod_epp keeps the connection, and its session cookie, after a logout. A new login replaces the choice.
send_frame($sock, login_frame(clid => 'foo', pw => 'bar', exturis => [$idn_uri, $marker], cltrid => new_cltrid()));
is_code(result_code(read_frame($sock)), 1000, 'second login on the same connection');
is_code(extensions(info_domain($sock)), 'idn:data', 'second login on the same connection: idn-1.0 replaces secDNS-1.1');
is_code(session_rows($marker), 1, 'second login stores one row');

# A session without a row, for example one the cleanup removed, falls back to every extension
$dbh->do(q{DELETE FROM `epp_session` WHERE CONCAT(' ', `exturis`, ' ') LIKE ?}, undef, "% $marker %");
is_code(extensions(info_domain($sock)), 'idn:data rgp:infData secDNS:infData', 'no session row: every extension, as before');
close($sock);

# The cron cleanup removes rows that have been idle too long and keeps the others
my $old = "cleanup-old-$$";
my $new = "cleanup-new-$$";
$dbh->do(q{INSERT INTO `epp_session` (`session`,`registrar_id`,`objuris`,`exturis`,`logged_in`,`last_used`)
	SELECT ?, `id`, '', ?, DATE_SUB(NOW(), INTERVAL 2 DAY), DATE_SUB(NOW(), INTERVAL 2 DAY) FROM `registrar` WHERE `clid` = 'foo'}, undef, $old, $marker);
$dbh->do(q{INSERT INTO `epp_session` (`session`,`registrar_id`,`objuris`,`exturis`,`logged_in`,`last_used`)
	SELECT ?, `id`, '', ?, NOW(), NOW() FROM `registrar` WHERE `clid` = 'foo'}, undef, $new, $marker);
system('perl -I/var/www/cgi-bin/epp/lib /var/www/cgi-bin/epp/cron/clean-epp-sessions.pl >/dev/null 2>&1');
my ($old_left) = $dbh->selectrow_array('SELECT COUNT(*) FROM `epp_session` WHERE `session` = ?', undef, $old);
my ($new_left) = $dbh->selectrow_array('SELECT COUNT(*) FROM `epp_session` WHERE `session` = ?', undef, $new);
is_code($old_left, 0, 'cleanup removes an idle row');
is_code($new_left, 1, 'cleanup keeps a recent row');
$dbh->do('DELETE FROM `epp_session` WHERE `session` = ?', undef, $new);

# Leave nothing behind for a kept stack
my $cleanup = login(@all);
command_code($cleanup, qq{<delete><domain:delete $domain_ns><domain:name>$name</domain:name></domain:delete></delete>});
command_code($cleanup, qq{<delete><contact:delete $contact_ns><contact:id>$contact</contact:id></contact:delete></delete>});
close($cleanup);

done_testing();
