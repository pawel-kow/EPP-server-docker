# RFC 5910 DS data on domains: domain:create and domain:update stored nothing and domain:info
# answered no secDNS:infData, while the greeting advertised secDNS-1.1 (pawel-kow/epp#8).
# Credentials are the REG1_* defaults in docker-compose.yml.

# DBI is not core Perl, but the CGI scripts need it, so the image always has it
use lib '/var/www/cgi-bin/epp/lib';
use DBI;
use EPP::Config();

my %c = %EPP::Config::c;
my $dbh = DBI->connect("DBI:mysql:$c{mysql_database}:$c{mysql_host}:$c{mysql_port}",
	$c{mysql_username}, $c{mysql_password}, { RaiseError => 1 });

my $domain_ns = 'xmlns:domain="urn:ietf:params:xml:ns:domain-1.0"';
my $secdns_ns = 'xmlns:secDNS="urn:ietf:params:xml:ns:secDNS-1.1"';

my ($tld) = $dbh->selectrow_array('SELECT `tld` FROM `domain_tld` LIMIT 1');
$tld =~ s/^\.//;

my $sock = epp_session(clid => 'foo', pw => 'bar');

my $domain_seq = 0;
sub new_domain { return lc(sprintf('secdns-%d-%d-%d.%s', time(), $$, ++$domain_seq, $tld)); }

my $sha1 = '49FD46E6C4B45C55D4AC49FD46E6C4B45C55D4AC';
my $sha256 = 'E2D3C916F6DEEAC73294E8268FB5885044A833FC5459588F4A9184CFC41A5766';
my $sha256b = 'A1B2C3D4E5F60718293A4B5C6D7E8F90A1B2C3D4E5F60718293A4B5C6D7E8F90';

sub ds_xml {
	my ($keytag, $alg, $type, $digest, $key) = @_;
	return qq{<secDNS:dsData><secDNS:keyTag>$keytag</secDNS:keyTag><secDNS:alg>$alg</secDNS:alg>}
		. qq{<secDNS:digestType>$type</secDNS:digestType><secDNS:digest>$digest</secDNS:digest>}
		. ($key // '') . q{</secDNS:dsData>};
}

my $key_xml = q{<secDNS:keyData><secDNS:flags>257</secDNS:flags><secDNS:protocol>3</secDNS:protocol>}
	. q{<secDNS:alg>13</secDNS:alg><secDNS:pubKey>AQPJ////4Q==</secDNS:pubKey></secDNS:keyData>};

sub create_code {
	my ($name, $secdns) = @_;
	my $ext = defined $secdns ? qq{<extension><secDNS:create $secdns_ns>$secdns</secDNS:create></extension>} : '';
	return command_code($sock, qq{<create><domain:create $domain_ns><domain:name>$name</domain:name>}
		. q{<domain:period unit="y">1</domain:period><domain:authInfo><domain:pw>Secret123</domain:pw></domain:authInfo>}
		. qq{</domain:create></create>$ext});
}

sub update_code {
	my ($name, $secdns, $attrs) = @_;
	$attrs //= '';
	return command_code($sock, qq{<update><domain:update $domain_ns><domain:name>$name</domain:name></domain:update></update>}
		. qq{<extension><secDNS:update $secdns_ns$attrs>$secdns</secDNS:update></extension>});
}

sub info_reply {
	my ($name) = @_;
	return command_reply($sock, qq{<info><domain:info $domain_ns><domain:name>$name</domain:name></domain:info></info>});
}

# "keyTag/alg/digestType/digest" of every dsData in the reply, in order
sub info_ds {
	my ($name) = @_;
	my $reply = info_reply($name) // '';
	my @ds;
	while ($reply =~ m{<secDNS:dsData>(.*?)</secDNS:dsData>}gs) {
		my $d = $1;
		push @ds, join('/', map { $d =~ m{<secDNS:$_>([^<]*)</secDNS:$_>} ? $1 : '?' } qw(keyTag alg digestType digest));
	}
	return join(' ', @ds);
}

sub info_max_sig_life {
	my ($name) = @_;
	return (info_reply($name) // '') =~ m{<secDNS:maxSigLife>(\d+)</secDNS:maxSigLife>} ? $1 : '(none)';
}

# The reproducer of the issue
my $name = new_domain();
is_code(create_code($name, ds_xml(12345, 13, 2, $sha256)), 1000, 'create with dsData');
my $reply = info_reply($name);
is_code(result_code($reply), 1000, 'info of a domain with dsData');
is_code(($reply // '') =~ m{<secDNS:infData\b[^>]*xmlns:secDNS="urn:ietf:params:xml:ns:secDNS-1\.1"} ? 1 : 0, 1, 'info has secDNS:infData');
is_code(info_ds($name), "12345/13/2/$sha256", 'info returns the created dsData');
is_code(info_max_sig_life($name), '(none)', 'no maxSigLife unless the client set one');

# No DS data, no extension element
my $plain = new_domain();
is_code(create_code($plain), 1000, 'create without secDNS');
is_code((info_reply($plain) // '') =~ /secDNS:infData/ ? 1 : 0, 0, 'info without DS data has no secDNS:infData');

# maxSigLife, several dsData and a keyData child
my $full = new_domain();
is_code(create_code($full, '<secDNS:maxSigLife>604800</secDNS:maxSigLife>'
	. ds_xml(1, 13, 2, $sha256, $key_xml) . ds_xml(2, 8, 1, $sha1)), 1000, 'create with maxSigLife and keyData child');
is_code(info_ds($full), "1/13/2/$sha256 2/8/1/$sha1", 'info returns every dsData');
is_code(info_max_sig_life($full), 604800, 'info returns maxSigLife');
$reply = info_reply($full) // '';
is_code($reply =~ m{<secDNS:keyData>\s*<secDNS:flags>257</secDNS:flags>\s*<secDNS:protocol>3</secDNS:protocol>\s*<secDNS:alg>13</secDNS:alg>\s*<secDNS:pubKey>AQPJ////4Q==</secDNS:pubKey>\s*</secDNS:keyData>\s*</secDNS:dsData>} ? 1 : 0,
	1, 'info returns the keyData child');

# Refused creates leave no domain behind
foreach my $case (
	['keyData interface', $key_xml, 2306],
	['no dsData', '<secDNS:maxSigLife>604800</secDNS:maxSigLife>', 2003],
	['missing digest', q{<secDNS:dsData><secDNS:keyTag>1</secDNS:keyTag><secDNS:alg>13</secDNS:alg><secDNS:digestType>2</secDNS:digestType></secDNS:dsData>}, 2003],
	['non-numeric keyTag', ds_xml('abc', 13, 2, $sha256), 2005],
	['keyTag out of range', ds_xml(65536, 13, 2, $sha256), 2004],
	['alg out of range', ds_xml(1, 256, 2, $sha256), 2004],
	['non-hex digest', ds_xml(1, 13, 2, 'Z' x 64), 2005],
	['digest of the wrong length', ds_xml(1, 13, 2, $sha1), 2306],
	['digestType that does not fit the schema', ds_xml(1, 14, 4, 'A' x 96), 2306],
	['same digest twice', ds_xml(1, 13, 2, $sha256) . ds_xml(2, 13, 2, $sha256), 2306],
	['maxSigLife of zero', '<secDNS:maxSigLife>0</secDNS:maxSigLife>' . ds_xml(1, 13, 2, $sha256), 2004],
	['pubKey over the column size', ds_xml(1, 13, 2, $sha256, $key_xml =~ s/AQPJ\S*Q==/'A' x 256/er), 2306],
) {
	my ($label, $xml, $want) = @$case;
	my $refused = new_domain();
	is_code(create_code($refused, $xml), $want, "create refused: $label");
	is_code(result_code(info_reply($refused)), 2303, "create refused: $label leaves no domain");
}

# update: add, rem, both at once, rem all
my $upd = new_domain();
is_code(create_code($upd), 1000, 'create for update');
is_code(update_code($upd, '<secDNS:add>' . ds_xml(1, 13, 2, $sha256) . ds_xml(2, 8, 1, $sha1) . '</secDNS:add>'), 1000, 'update adds dsData');
is_code(info_ds($upd), "1/13/2/$sha256 2/8/1/$sha1", 'info after add');
is_code(update_code($upd, '<secDNS:rem>' . ds_xml(2, 8, 1, $sha1) . '</secDNS:rem>'), 1000, 'update removes dsData');
is_code(info_ds($upd), "1/13/2/$sha256", 'info after rem');
is_code(update_code($upd, '<secDNS:rem>' . ds_xml(1, 13, 2, lc($sha256)) . '</secDNS:rem><secDNS:add>' . ds_xml(9, 13, 2, $sha256) . '</secDNS:add>'),
	1000, 'rem goes first, so the same digest can be added again, and case does not matter');
is_code(info_ds($upd), "9/13/2/$sha256", 'info after rem and add');
is_code(update_code($upd, '<secDNS:chg><secDNS:maxSigLife>86400</secDNS:maxSigLife></secDNS:chg>'), 1000, 'update changes maxSigLife');
is_code(info_max_sig_life($upd), 86400, 'info after chg');
is_code(update_code($upd, '<secDNS:add>' . ds_xml(3, 8, 1, $sha1) . '</secDNS:add>'), 1000, 'update adds to a domain with maxSigLife');
is_code(update_code($upd, '<secDNS:rem>' . ds_xml(9, 13, 2, $sha256) . '</secDNS:rem>'), 1000, 'update removes the older row');
is_code(info_max_sig_life($upd), 86400, 'maxSigLife applies to added rows too');
is_code(update_code($upd, '<secDNS:rem><secDNS:all>false</secDNS:all></secDNS:rem>'), 1000, 'rem all false');
is_code(info_ds($upd), "3/8/1/$sha1", 'rem all false removes nothing');

# Refused updates change nothing
foreach my $case (
	['keyData interface', '<secDNS:add>' . $key_xml . '</secDNS:add>', '', 2306],
	['rem keyData', '<secDNS:rem>' . $key_xml . '</secDNS:rem>', '', 2306],
	['urgent', '<secDNS:rem><secDNS:all>true</secDNS:all></secDNS:rem>', ' urgent="true"', 2102],
	['nothing to do', '', '', 2003],
	['rem all and dsData', '<secDNS:rem><secDNS:all>true</secDNS:all>' . ds_xml(3, 8, 1, $sha1) . '</secDNS:rem>', '', 2005],
	['duplicate add', '<secDNS:add>' . ds_xml(3, 8, 1, $sha1) . '</secDNS:add>', '', 2306],
	['rem of unknown dsData', '<secDNS:rem>' . ds_xml(4, 8, 1, $sha1) . '</secDNS:rem>', '', 2306],
	['valid rem, invalid add', '<secDNS:rem><secDNS:all>true</secDNS:all></secDNS:rem><secDNS:add>' . ds_xml('x', 8, 1, $sha1) . '</secDNS:add>', '', 2005],
) {
	my ($label, $xml, $attrs, $want) = @$case;
	is_code(update_code($upd, $xml, $attrs), $want, "update refused: $label");
	is_code(info_ds($upd), "3/8/1/$sha1", "update refused: $label changes nothing");
}

is_code(update_code($upd, '<secDNS:rem><secDNS:all>true</secDNS:all></secDNS:rem>'), 1000, 'rem all true');
is_code((info_reply($upd) // '') =~ /secDNS:infData/ ? 1 : 0, 0, 'no secDNS:infData once all dsData are gone');
is_code(update_code($upd, '<secDNS:chg><secDNS:maxSigLife>86400</secDNS:maxSigLife></secDNS:chg>'), 2306, 'maxSigLife has nowhere to go without dsData');

# Only the sponsor may update
my $other = epp_session(clid => 'baz', pw => 'qux');
is_code(command_code($other, qq{<update><domain:update $domain_ns><domain:name>$name</domain:name></domain:update></update>}
	. qq{<extension><secDNS:update $secdns_ns><secDNS:rem><secDNS:all>true</secDNS:all></secDNS:rem></secDNS:update></extension>}), 2201, 'update by another registrar');
close($other);
is_code(info_ds($name), "12345/13/2/$sha256", 'update by another registrar changes nothing');

# secdns has a RESTRICT foreign key on domain, so both delete paths have to clear it
# The server answers 1001 for every delete, even this immediate one
my $del = new_domain();
is_code(create_code($del, ds_xml(1, 13, 2, $sha256)), 1000, 'create for delete');
is_code(command_code($sock, qq{<delete><domain:delete $domain_ns><domain:name>$del</domain:name></domain:delete></delete>}), 1001, 'delete in addPeriod');
is_code(result_code(info_reply($del)), 2303, 'delete in addPeriod removes the domain');

my $purged = new_domain();
is_code(create_code($purged, ds_xml(1, 13, 2, $sha256)), 1000, 'create for purge');
$dbh->do(q{UPDATE `domain` SET `rgpstatus` = 'pendingDelete', `delTime` = DATE_SUB(NOW(), INTERVAL 36 DAY) WHERE `name` = ?}, undef, uc($purged));
my ($purged_id) = $dbh->selectrow_array('SELECT `id` FROM `domain` WHERE `name` = ?', undef, uc($purged));
$dbh->do(q{INSERT INTO `domain_status` (`domain_id`,`status`) VALUES(?,'pendingDelete')}, undef, $purged_id);
system('perl -I/var/www/cgi-bin/epp/lib /var/www/cgi-bin/epp/cron/change-domain-status.pl >/dev/null 2>&1');
is_code(result_code(info_reply($purged)), 2303, 'the cron purge removes a domain with dsData');

close($sock);
done_testing();
