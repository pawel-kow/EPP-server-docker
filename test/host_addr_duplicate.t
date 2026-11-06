# host:update must answer when <host:add> names an address the host already has. The check for
# it compared `ip` with '4' and '6' while the column holds 'v4' and 'v6', so it never matched,
# the INSERT hit the unique key and the script died with no reply (pawel-kow/epp#4).
# Credentials are the REG1_* defaults in docker-compose.yml.

# DBI is not core Perl, but the CGI scripts need it, so the image always has it
use lib '/var/www/cgi-bin/epp/lib';
use DBI;
use EPP::Config();

my %c = %EPP::Config::c;
my $dbh = DBI->connect("DBI:mysql:$c{mysql_database}:$c{mysql_host}:$c{mysql_port}",
	$c{mysql_username}, $c{mysql_password}, { RaiseError => 1 });

my $host_ns = 'xmlns:host="urn:ietf:params:xml:ns:host-1.0"';
my %login = (clid => 'foo', pw => 'bar');

# A host can only have addresses below a domain of this registry, and the path to a domain
# through EPP (contacts, prices) is not what is under test here
my ($registrar_id) = $dbh->selectrow_array("SELECT `id` FROM `registrar` WHERE `clid` = 'foo'");
my ($tld_id, $tld) = $dbh->selectrow_array('SELECT `id`,`tld` FROM `domain_tld` LIMIT 1');
$tld =~ s/^\.//;
my $domain = lc(sprintf('dup-addr-%d-%d.%s', time(), $$, $tld));
$dbh->do('INSERT INTO `domain` (`name`,`tldid`,`crdate`,`exdate`,`clid`,`crid`)'
	. ' VALUES (?,?,NOW(),DATE_ADD(NOW(), INTERVAL 1 YEAR),?,?)',
	undef, $domain, $tld_id, $registrar_id, $registrar_id);

my $host_seq = 0;

sub addr_xml {
	return join('', map { qq{<host:addr ip="$_->[0]">$_->[1]</host:addr>} } @_);
}

# Every case has its own session, so that a command with no reply cannot affect the next one
sub in_session {
	my ($body) = @_;
	my $sock = epp_session(%login);
	my $code = command_code($sock, $body);
	close($sock);
	return $code;
}

sub new_host {
	my (@addrs) = @_;
	my $name = 'ns' . ++$host_seq . ".$domain";
	is_code(in_session(qq{<create><host:create $host_ns><host:name>$name</host:name>}
		. addr_xml(@addrs) . q{</host:create></create>}), 1000, "create $name");
	return $name;
}

sub update_code {
	my ($name, $inner) = @_;
	return in_session(qq{<update><host:update $host_ns><host:name>$name</host:name>$inner</host:update></update>});
}

# The addresses stored for a host, sorted and comma separated
sub stored {
	my ($name) = @_;
	my $rows = $dbh->selectcol_arrayref('SELECT `host_addr`.`addr` FROM `host_addr`,`host`'
		. ' WHERE `host_addr`.`host_id` = `host`.`id` AND `host`.`name` = ? ORDER BY `host_addr`.`addr`',
		undef, $name);
	return join(',', @$rows);
}

my @v4 = ('v4', '198.51.100.1');
my @v6 = ('v6', '2001:db8::1');

# The case from the issue, and the same for IPv6
my $host = new_host([@v4], [@v6]);
is_code(update_code($host, '<host:add>' . addr_xml([@v4]) . '</host:add>'), 2306, 'add an existing IPv4 address');
is_code(update_code($host, '<host:add>' . addr_xml([@v6]) . '</host:add>'), 2306, 'add an existing IPv6 address');
is_code(stored($host), '198.51.100.1,2001:db8::1', 'refused adds change nothing');

# The address is compared after normalising
is_code(update_code($host, '<host:add>' . addr_xml(['v4', '198.051.100.001']) . '</host:add>'), 2306,
	'add an existing IPv4 address written with leading zeros');

# Control: the check must not refuse an address the host does not have
is_code(update_code($host, '<host:add>' . addr_xml(['v4', '198.51.100.2']) . '</host:add>'), 1000, 'add a new address');
is_code(stored($host), '198.51.100.1,198.51.100.2,2001:db8::1', 'the new address is stored');

# Nothing is written when one address of the command is refused
$host = new_host([@v4]);
is_code(update_code($host, '<host:add>' . addr_xml(['v4', '198.51.100.3'], [@v4]) . '</host:add>'), 2306,
	'add a new and an existing address');
is_code(stored($host), '198.51.100.1', 'the new address of a refused command is not stored');

# The same address twice in one command gets past a check against the table
$host = new_host();
is_code(update_code($host, '<host:add>' . addr_xml([@v4], [@v4]) . '</host:add>'), 2306, 'add one IPv4 address twice');
is_code(update_code($host, '<host:add>' . addr_xml([@v6], [@v6]) . '</host:add>'), 2306, 'add one IPv6 address twice');
is_code(update_code($host, '<host:add>' . addr_xml([@v4], ['v4', '198.051.100.001']) . '</host:add>'), 2306,
	'add one address twice in different forms');
is_code(stored($host), '', 'nothing of a refused duplicate is stored');

# <host:rem> runs before <host:add>, so an address in both is removed and added back
$host = new_host([@v4]);
is_code(update_code($host, '<host:add>' . addr_xml([@v4]) . '</host:add><host:rem>' . addr_xml([@v4]) . '</host:rem>'), 1000,
	'remove and add the same address');
is_code(stored($host), '198.51.100.1', 'the address is there once afterwards');

# A <host:rem> in another form deletes nothing, so it must not excuse the add
is_code(update_code($host, '<host:add>' . addr_xml([@v4]) . '</host:add><host:rem>' . addr_xml(['v4', '198.051.100.001']) . '</host:rem>'), 2306,
	'remove in another form and add the same address');

# Rows written before the type was stored correctly hold an empty enum, and must count too
$host = new_host();
my ($host_id) = $dbh->selectrow_array('SELECT `id` FROM `host` WHERE `name` = ?', undef, $host);
$dbh->do("SET SESSION sql_mode = ''");
{
	local $dbh->{PrintWarn} = 0;
	$dbh->do("INSERT INTO `host_addr` (`host_id`,`addr`,`ip`) VALUES (?,'198.51.100.1','')", undef, $host_id);
}
is_code(update_code($host, '<host:add>' . addr_xml([@v4]) . '</host:add>'), 2306, 'add an address held by a legacy row');
is_code(stored($host), '198.51.100.1', 'a legacy row gets no second row');

done_testing();
