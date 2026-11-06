# RFC 5732 allows only "v4" and "v6" in the ip attribute of host:addr. The server used to answer
# ip="v" for an address from host:create and ip="vv4" for one from host:update
# (pawel-kow/epp#5). Credentials are the REG1_* defaults in docker-compose.yml.

# DBI is not core Perl, but the CGI scripts need it, so the image always has it
use lib '/var/www/cgi-bin/epp/lib';
use DBI;
use EPP::Config();

my %c = %EPP::Config::c;
my $dbh = DBI->connect("DBI:mysql:$c{mysql_database}:$c{mysql_host}:$c{mysql_port}",
	$c{mysql_username}, $c{mysql_password}, { RaiseError => 1 });

my $host_ns = 'xmlns:host="urn:ietf:params:xml:ns:host-1.0"';

# A host can only have addresses below a domain of this registry, and the path to a domain
# through EPP (contacts, prices) is not what is under test here
my ($registrar_id) = $dbh->selectrow_array("SELECT `id` FROM `registrar` WHERE `clid` = 'foo'");
my ($tld_id, $tld) = $dbh->selectrow_array('SELECT `id`,`tld` FROM `domain_tld` LIMIT 1');
$tld =~ s/^\.//;
my $domain = lc(sprintf('ip-attr-%d-%d.%s', time(), $$, $tld));
$dbh->do('INSERT INTO `domain` (`name`,`tldid`,`crdate`,`exdate`,`clid`,`crid`)'
	. ' VALUES (?,?,NOW(),DATE_ADD(NOW(), INTERVAL 1 YEAR),?,?)',
	undef, $domain, $tld_id, $registrar_id, $registrar_id);

my $sock = epp_session(clid => 'foo', pw => 'bar');

sub addr_xml {
	my (@addrs) = @_;
	return join('', map {
		my ($ip, $addr) = @$_;
		defined $ip ? qq{<host:addr ip="$ip">$addr</host:addr>} : qq{<host:addr>$addr</host:addr>};
	} @addrs);
}

sub create_host {
	my ($label, @addrs) = @_;
	my $name = "$label.$domain";
	is_code(command_code($sock, qq{<create><host:create $host_ns><host:name>$name</host:name>}
		. addr_xml(@addrs) . q{</host:create></create>}), 1000, "$label: host:create");
	return $name;
}

# The ip attribute of every host:addr in the host:info reply, by address
sub info_ips {
	my ($name) = @_;
	my $reply = command_reply($sock, qq{<info><host:info $host_ns><host:name>$name</host:name></host:info></info>});
	is_code(result_code($reply), 1000, "$name: host:info");
	my %ips;
	while (($reply // '') =~ m{<host:addr\b([^>]*)>([^<]*)</host:addr>}g) {
		my ($attrs, $addr) = ($1, $2);
		$ips{$addr} = $attrs =~ /\bip="([^"]*)"/ ? $1 : '(none)';
	}
	return \%ips;
}

sub stored_ip {
	my ($name, $addr) = @_;
	my ($ip) = $dbh->selectrow_array('SELECT `host_addr`.`ip` FROM `host_addr`,`host`'
		. ' WHERE `host_addr`.`host_id` = `host`.`id` AND `host`.`name` = ? AND `host_addr`.`addr` = ?',
		undef, $name, $addr);
	return $ip;
}

# host:create, both families
my $created = create_host('ns1', ['v4', '192.0.2.1'], ['v6', '2001:db8::1']);
my $ips = info_ips($created);
is_code($ips->{'192.0.2.1'}, 'v4', 'create: ip of an IPv4 address');
is_code($ips->{'2001:db8::1'}, 'v6', 'create: ip of an IPv6 address');
is_code(stored_ip($created, '192.0.2.1'), 'v4', 'create: IPv4 type is stored');
is_code(stored_ip($created, '2001:db8::1'), 'v6', 'create: IPv6 type is stored');

# The attribute is optional and defaults to v4
my $default = create_host('ns2', [undef, '192.0.2.2']);
is_code(info_ips($default)->{'192.0.2.2'}, 'v4', 'create without ip: answered as v4');
is_code(stored_ip($default, '192.0.2.2'), 'v4', 'create without ip: stored as v4');

# host:update, both families
my $updated = create_host('ns3');
is_code(command_code($sock, qq{<update><host:update $host_ns><host:name>$updated</host:name><host:add>}
	. addr_xml(['v4', '198.51.100.1'], ['v6', '2001:db8::2'])
	. q{</host:add></host:update></update>}), 1000, 'host:update adds addresses');
$ips = info_ips($updated);
is_code($ips->{'198.51.100.1'}, 'v4', 'update: ip of an IPv4 address');
is_code($ips->{'2001:db8::2'}, 'v6', 'update: ip of an IPv6 address');
is_code(stored_ip($updated, '198.51.100.1'), 'v4', 'update: IPv4 type is stored');
is_code(stored_ip($updated, '2001:db8::2'), 'v6', 'update: IPv6 type is stored');

# Rows written before the fix hold an empty enum, and existing data is not migrated
my $legacy = create_host('ns4');
my ($legacy_id) = $dbh->selectrow_array('SELECT `id` FROM `host` WHERE `name` = ?', undef, $legacy);
$dbh->do("SET SESSION sql_mode = ''");
{
	local $dbh->{PrintWarn} = 0;
	$dbh->do("INSERT INTO `host_addr` (`host_id`,`addr`,`ip`) VALUES (?,'192.0.2.3',''),(?,'2001:db8::3','')",
		undef, $legacy_id, $legacy_id);
}
is_code(stored_ip($legacy, '192.0.2.3'), '', 'legacy: the row has an empty type');
$ips = info_ips($legacy);
is_code($ips->{'192.0.2.3'}, 'v4', 'legacy: ip of an IPv4 address');
is_code($ips->{'2001:db8::3'}, 'v6', 'legacy: ip of an IPv6 address');

close($sock);
done_testing();
