# <add> of a status in host:update, contact:update and domain:update must always be answered. The
# scripts checked the status against the table only, so one listed twice in a command got past
# the check, the second INSERT hit the unique key and the script died with no reply.
# Credentials are the REG1_* defaults in docker-compose.yml.

# DBI is not core Perl, but the CGI scripts need it, so the image always has it
use lib '/var/www/cgi-bin/epp/lib';
use DBI;
use EPP::Config();

my %c = %EPP::Config::c;
my $dbh = DBI->connect("DBI:mysql:$c{mysql_database}:$c{mysql_host}:$c{mysql_port}",
	$c{mysql_username}, $c{mysql_password}, { RaiseError => 1 });

my %login = (clid => 'foo', pw => 'bar');
my ($registrar_id) = $dbh->selectrow_array("SELECT `id` FROM `registrar` WHERE `clid` = 'foo'");
my ($tld_id, $tld) = $dbh->selectrow_array('SELECT `id`,`tld` FROM `domain_tld` LIMIT 1');
$tld =~ s/^\.//;
my $run = sprintf('%d-%d', time(), $$);
my $seq = 0;

# The objects are seeded because the way to them through EPP is not what is under test here
sub seed_domain {
	my $name = lc(sprintf('dup-status-%s-%d.%s', $run, ++$seq, $tld));
	$dbh->do('INSERT INTO `domain` (`name`,`tldid`,`crdate`,`exdate`,`clid`,`crid`)'
		. ' VALUES (?,?,NOW(),DATE_ADD(NOW(), INTERVAL 1 YEAR),?,?)',
		undef, $name, $tld_id, $registrar_id, $registrar_id);
	return $name;
}

sub seed_contact {
	my $name = sprintf('FO-%s-%d', $run, ++$seq);
	$dbh->do('INSERT INTO `contact` (`identifier`,`email`,`clid`,`crid`,`crdate`) VALUES (?,?,?,?,NOW())',
		undef, $name, 'dup-status@example.com', $registrar_id, $registrar_id);
	return $name;
}

sub seed_host {
	my $domain = seed_domain();
	my ($domain_id) = $dbh->selectrow_array('SELECT `id` FROM `domain` WHERE `name` = ?', undef, $domain);
	my $name = uc("ns1.$domain");
	$dbh->do('INSERT INTO `host` (`name`,`domain_id`,`clid`,`crid`,`crdate`) VALUES (?,?,?,?,NOW())',
		undef, $name, $domain_id, $registrar_id, $registrar_id);
	return $name;
}

my %objects = (
	host    => { key => 'name', seed => \&seed_host,    table => 'host',    column => 'name' },
	contact => { key => 'id',   seed => \&seed_contact, table => 'contact', column => 'identifier' },
	domain  => { key => 'name', seed => \&seed_domain,  table => 'domain',  column => 'name' },
);

# Every case has its own session, so that a command with no reply cannot affect the next one
sub update_code {
	my ($type, $name, $inner) = @_;
	my $key = $objects{$type}{key};
	my $sock = epp_session(%login);
	my $code = command_code($sock, qq{<update><$type:update xmlns:$type="urn:ietf:params:xml:ns:$type-1.0">}
		. qq{<$type:$key>$name</$type:$key>$inner</$type:update></update>});
	close($sock);
	return $code;
}

sub stored {
	my ($type, $name) = @_;
	my $o = $objects{$type};
	my $rows = $dbh->selectcol_arrayref("SELECT `s`.`status` FROM `${type}_status` AS `s`, `$o->{table}` AS `o`"
		. " WHERE `s`.`${type}_id` = `o`.`id` AND `o`.`$o->{column}` = ? ORDER BY `s`.`status`+0",
		undef, $name);
	return join(',', @$rows);
}

sub statuses {
	my ($type, @names) = @_;
	return join('', map { qq{<$type:status s="$_"/>} } @names);
}

# domain:add and domain:rem have the same form as the others for a status
sub add { my ($type, @s) = @_; return "<$type:add>" . statuses($type, @s) . "</$type:add>"; }
sub rem { my ($type, @s) = @_; return "<$type:rem>" . statuses($type, @s) . "</$type:rem>"; }

my ($first, $second) = qw(clientDeleteProhibited clientUpdateProhibited);

for my $type (sort keys %objects) {
	my $seed = $objects{$type}{seed};

	# Control: two different statuses in one command
	my $name = $seed->();
	is_code(update_code($type, $name, add($type, $first, $second)), 1000, "$type: add two statuses");
	is_code(stored($type, $name), "$first,$second", "$type: both are stored");

	# A status the object has
	$name = $seed->();
	is_code(update_code($type, $name, add($type, $first)), 1000, "$type: add a status");
	is_code(update_code($type, $name, add($type, $first)), 2306, "$type: add it again");
	is_code(stored($type, $name), $first, "$type: it is stored once");

	# The same status twice in one command, on its own and with another one
	$name = $seed->();
	is_code(update_code($type, $name, add($type, $first, $first)), 2306, "$type: add one status twice");
	is_code(stored($type, $name), '', "$type: nothing of a refused duplicate is stored");
	is_code(update_code($type, $name, add($type, $second, $first, $first)), 2306, "$type: add a status and another twice");
	is_code(stored($type, $name), '', "$type: the other status of a refused command is not stored");

	# <rem> runs before <add>, so a status in both is removed and added back, but only once
	$name = $seed->();
	is_code(update_code($type, $name, add($type, $first)), 1000, "$type: add a status to replace");
	is_code(update_code($type, $name, add($type, $first) . rem($type, $first)), 1000, "$type: remove and add the same status");
	is_code(stored($type, $name), $first, "$type: it is there once afterwards");
	is_code(update_code($type, $name, add($type, $first, $first) . rem($type, $first)), 2306, "$type: remove it and add it twice");
	is_code(stored($type, $name), $first, "$type: a refused command removes nothing");
}

# Host only: addresses are written before statuses
my $domain = seed_domain();
my ($domain_id) = $dbh->selectrow_array('SELECT `id` FROM `domain` WHERE `name` = ?', undef, $domain);
my $host = uc("ns2.$domain");
$dbh->do('INSERT INTO `host` (`name`,`domain_id`,`clid`,`crid`,`crdate`) VALUES (?,?,?,?,NOW())',
	undef, $host, $domain_id, $registrar_id, $registrar_id);
is_code(update_code('host', $host, '<host:add><host:addr ip="v4">192.0.2.1</host:addr>' . statuses('host', $first, $first) . '</host:add>'), 2306,
	'host: add an address and one status twice');
my ($addrs) = $dbh->selectrow_array('SELECT COUNT(*) FROM `host_addr`,`host` WHERE `host_addr`.`host_id` = `host`.`id` AND `host`.`name` = ?', undef, $host);
is_code($addrs, 0, 'host: the address of a refused command is not stored');

done_testing();
