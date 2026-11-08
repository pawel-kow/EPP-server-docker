# EPP IDN extension, urn:ietf:params:xml:ns:idn-1.0 (pawel-kow/epp#26). Every xn-- name was refused
# with 2306 on create, check and info, and the greeting advertised idnLang-1.0, which the server
# ignored. Credentials are the REG1_* defaults in docker-compose.yml. This file has no "use utf8":
# every literal below is the UTF-8 bytes that go over the wire. The A-labels were computed with
# Python's punycode codec, independently of the server.

use lib '/var/www/cgi-bin/epp/lib';
use DBI;
use EPP::Config();

my %c = %EPP::Config::c;
my $dbh = DBI->connect("DBI:mysql:$c{mysql_database}:$c{mysql_host}:$c{mysql_port}",
	$c{mysql_username}, $c{mysql_password}, { RaiseError => 1 });

my $idn_uri = 'urn:ietf:params:xml:ns:idn-1.0';
my $domain_ns = 'xmlns:domain="urn:ietf:params:xml:ns:domain-1.0"';
my $idn_ns = qq{xmlns:idn="$idn_uri"};

my ($tld) = $dbh->selectrow_array('SELECT `tld` FROM `domain_tld` LIMIT 1');
$tld =~ s/^\.//;
$tld = lc($tld);

# Greeting and login
my $greeting = greeting_frame() // '';
is_code($greeting =~ m{<extURI>\Q$idn_uri\E</extURI>} ? 1 : 0, 1, 'greeting advertises idn-1.0');
is_code($greeting =~ m{idnLang} ? 1 : 0, 0, 'greeting no longer advertises the unimplemented idnLang-1.0');
is_code(login_code(clid => 'foo', pw => 'bar', exturis => [$idn_uri]), 1000, 'login with the idn-1.0 extURI');

my $sock = epp_session(clid => 'foo', pw => 'bar', exturis => [$idn_uri]);

sub idn_ext {
	my ($table, $uname) = @_;
	my $inner = (defined $table ? "<idn:table>$table</idn:table>" : '') . (defined $uname ? "<idn:uname>$uname</idn:uname>" : '');
	return qq{<extension><idn:data $idn_ns>$inner</idn:data></extension>};
}

sub create_reply {
	my ($name, $ext) = @_;
	return command_reply($sock, qq{<create><domain:create $domain_ns><domain:name>$name</domain:name>}
		. q{<domain:period unit="y">1</domain:period><domain:authInfo><domain:pw>Secret123</domain:pw></domain:authInfo>}
		. qq{</domain:create></create>} . ($ext // ''));
}

sub create_code { return result_code(create_reply(@_)); }

sub info_reply {
	my ($name) = @_;
	return command_reply($sock, qq{<info><domain:info $domain_ns><domain:name>$name</domain:name></domain:info></info>});
}

# "table|uname" of the idn:data in an info reply, or "(none)"
sub info_idn {
	my ($name) = @_;
	my $reply = info_reply($name) // '';
	return '(none)' unless $reply =~ m{<idn:data\b[^>]*xmlns:idn="\Q$idn_uri\E"[^>]*>(.*?)</idn:data>}s;
	my $d = $1;
	my $table = $d =~ m{<idn:table>([^<]*)</idn:table>} ? $1 : '?';
	my $uname = $d =~ m{<idn:uname>([^<]*)</idn:uname>} ? $1 : '?';
	return "$table|$uname";
}

sub check_avail {
	my ($name) = @_;
	my $reply = command_reply($sock, qq{<check><domain:check $domain_ns><domain:name>$name</domain:name></domain:check></check>}) // '';
	return $reply =~ m{<domain:name avail="(\d)">} ? $1 : "unparsable: $reply";
}

sub delete_domain {
	my ($name) = @_;
	return command_code($sock, qq{<delete><domain:delete $domain_ns><domain:name>$name</domain:name></domain:delete></delete>});
}

my $buecher = "xn--bcher-kva.$tld";    # bücher
my $muenchen = "xn--mnchen-3ya.$tld";  # münchen
my $espanol = "xn--espaol-zwa.$tld";   # español

# Left over from an earlier run on a kept stack. A delete in addPeriod removes the domain at once.
delete_domain($_) foreach ($buecher, $muenchen, $espanol);

# A-label validation, RFC 5891 section 4.2, before any table is involved
is_code(check_avail($buecher), 1, 'check: a valid A-label is available');
is_code(result_code(info_reply($buecher)), 2303, 'info: a valid A-label that is not registered does not exist');
foreach my $case (
	['xn--abc-', 'decodes to ASCII only'],
	['xn--bcher-kv', 'incomplete punycode'],
	['xn--bcher', 'decodes to symbols'],
	['xn--bucher-xyd', 'is not in NFC'],
	['xn--bcher-dgd', 'starts with a combining mark'],
	['xn--bcher-2pa', 'has an uppercase letter'],
	['xn--ab---3ra', 'has hyphens in the third and fourth position'],
	['xn----dha', 'ends with a hyphen'],
	['xn--bcher-kva9876c', 'has a ZERO WIDTH JOINER'],
) {
	my ($label, $why) = @$case;
	is_code(check_avail("$label.$tld"), 0, "check: refused, $why");
	is_code(result_code(info_reply("$label.$tld")), 2306, "info: refused, $why");
	is_code(create_code("$label.$tld", idn_ext('de')), 2306, "create: refused, $why");
}

# The reproducer of the issue
is_code(create_code($buecher, idn_ext('de', "b\xc3\xbccher.$tld")), 1000, 'create an IDN with table and uname');
my $reply = info_reply($buecher);
is_code(result_code($reply), 1000, 'info of the IDN');
is_code(info_idn($buecher), "de|b\xc3\xbccher.$tld", 'info returns idn:data with table and uname');
is_code(check_avail($buecher), 0, 'check: a registered IDN is not available');
is_code(info_idn(uc($buecher)), "de|b\xc3\xbccher.$tld", 'info: A-labels compare without regard to case');

# uname is optional; info then gives the U-label form of the name
is_code(create_code($muenchen, idn_ext('de')), 1000, 'create an IDN without uname');
is_code(info_idn($muenchen), "de|m\xc3\xbcnchen.$tld", 'info derives the uname');

# The table decides which code points are allowed
is_code(create_code($espanol, idn_ext('de', "espa\xc3\xb1ol.$tld")), 2306, 'create: n with tilde is not in the de table');
is_code(result_code(info_reply($espanol)), 2303, 'a refused create leaves no domain');
is_code(create_code($espanol, idn_ext('es', "espa\xc3\xb1ol.$tld")), 1000, 'create: n with tilde is in the es table');
is_code(info_idn($espanol), "es|espa\xc3\xb1ol.$tld", 'info returns the es table');

# Refused creates leave no domain behind
my $free = "xn--strae-oqa.$tld";  # straße
delete_domain($free);
foreach my $case (
	['no extension', undef, 2003],
	['no idn:table', idn_ext(undef, "stra\xc3\x9fe.$tld"), 2003],
	['unknown idn:table', idn_ext('xx', "stra\xc3\x9fe.$tld"), 2306],
	['uname of another name', idn_ext('de', "strasse.$tld"), 2306],
	['uname with another U-label', idn_ext('de', "stra\xc3\x9fen.$tld"), 2306],
	['uname with another TLD', idn_ext('de', "stra\xc3\x9fe.other"), 2306],
) {
	my ($label, $ext, $want) = @$case;
	is_code(create_code($free, $ext), $want, "create refused: $label");
	is_code(result_code(info_reply($free)), 2303, "create refused: $label leaves no domain");
}

# idn:data is for IDNs only, and an ASCII name has no idn:data in info
my $ascii = sprintf('idn-ascii-%d-%d.%s', time(), $$, $tld);
is_code(create_code($ascii, idn_ext('de', $ascii)), 2306, 'create: idn:data on an ASCII name is refused');
is_code(create_code($ascii), 1000, 'create an ASCII name');
is_code(info_idn($ascii), '(none)', 'info of an ASCII name has no idn:data');

# The other domain commands find the IDN by its A-label
is_code(delete_domain($muenchen), 1001, 'delete an IDN');
is_code(result_code(info_reply($muenchen)), 2303, 'the deleted IDN is gone');
is_code(create_code($muenchen, idn_ext('de', "mu\xcc\x88nchen.$tld")), 2306, 'create: a uname that is not in NFC is refused');
is_code(create_code($muenchen, idn_ext('de', "m\xc3\xbcnchen.$tld")), 1000, 'the A-label can be registered again');
is_code(info_idn($muenchen), "de|m\xc3\xbcnchen.$tld", 'info returns the new idn:data');

close($sock);
done_testing();
