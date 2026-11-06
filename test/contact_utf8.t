# RFC 5733 allows UTF-8 in <contact:postalInfo type="loc"> and limits type="int" to ASCII. The
# scripts held loc to ASCII as well, and answered with characters printed as Latin-1 in a document
# declared as UTF-8. Non-ASCII data has to reach the table as UTF-8 and come back byte for byte.
# Credentials are the REG1_* defaults in docker-compose.yml. This file has no "use utf8": every
# literal below is the UTF-8 bytes that go over the wire.

use lib '/var/www/cgi-bin/epp/lib';
use DBI;
use EPP::Config();

my %c = %EPP::Config::c;
my $dbh = DBI->connect("DBI:mysql:$c{mysql_database}:$c{mysql_host}:$c{mysql_port}",
	$c{mysql_username}, $c{mysql_password}, { RaiseError => 1 });

my $contact_ns = 'xmlns:contact="urn:ietf:params:xml:ns:contact-1.0"';
my $seq = 0;

sub new_id { return sprintf('FO-u%d%d', $$, ++$seq); }

sub postal_info {
	my (%a) = @_;
	my $org = defined $a{org} ? '<contact:org>' . ($a{org} =~ s/&/&amp;/gr) . '</contact:org>' : '';
	my $sp = defined $a{sp} ? "<contact:sp>$a{sp}</contact:sp>" : '';
	my $type = $a{type} // 'loc';
	return qq{<contact:postalInfo type="$type"><contact:name>$a{name}</contact:name>$org<contact:addr>}
		. qq{<contact:street>$a{street}</contact:street><contact:city>$a{city}</contact:city>$sp}
		. qq{<contact:pc>80331</contact:pc><contact:cc>DE</contact:cc></contact:addr></contact:postalInfo>};
}

sub create_body {
	my ($id, @postal) = @_;
	return qq{<create><contact:create $contact_ns><contact:id>$id</contact:id>}
		. join('', @postal)
		. qq{<contact:voice>+49.891234567</contact:voice><contact:email>utf8\@example.com</contact:email>}
		. qq{<contact:authInfo><contact:pw>Sw0rd-fish!Xy</contact:pw></contact:authInfo></contact:create></create>};
}

sub info_body { return qq{<info><contact:info $contact_ns><contact:id>$_[0]</contact:id></contact:info></info>}; }

sub update_body {
	my ($id, $postal) = @_;
	return qq{<update><contact:update $contact_ns><contact:id>$id</contact:id>}
		. qq{<contact:chg>$postal</contact:chg></contact:update></update>};
}

sub contains {
	my ($reply, $text, $name) = @_;
	is_code(defined $reply && index($reply, $text) >= 0 ? 'found' : 'missing: ' . ($reply // 'no reply'), 'found', $name);
}

sub valid_utf8 {
	my ($reply, $name) = @_;
	my $copy = $reply // '';
	is_code(utf8::decode($copy) ? 'valid' : "invalid: $reply", 'valid', $name);
}

# HEX() shows the stored bytes whatever charset the connection uses
sub stored_as {
	my ($sql, $bind, $text, $name) = @_;
	my ($hex) = $dbh->selectrow_array($sql, undef, @$bind);
	is_code($hex, uc(unpack('H*', $text)), $name);
}

sub stored_postal {
	my ($id, $column, $text, $name) = @_;
	stored_as("SELECT HEX(p.`$column`) FROM `contact_postalInfo` p JOIN `contact` c ON c.`id` = p.`contact_id`"
		. " WHERE c.`identifier` = ? AND p.`type` = 'loc'", [$id], $text, $name);
}

my $sock = epp_session(clid => 'foo', pw => 'bar');

# Latin letters with diacritics: the case in the report
my %german = (name => 'Jörg Müller', org => 'Müller & Söhne', street => 'Hauptstraße 5', city => 'München', sp => 'Bayern');
my $id = new_id();
my $reply = command_reply($sock, create_body($id, postal_info(%german)));
is_code(result_code($reply), '1000', 'loc with diacritics is accepted');
stored_postal($id, $_, $german{$_}, "$_ is stored as UTF-8") for qw(name org);
stored_postal($id, 'street1', $german{street}, 'street is stored as UTF-8');
stored_postal($id, 'city', $german{city}, 'city is stored as UTF-8');

$reply = command_reply($sock, info_body($id));
is_code(result_code($reply), '1000', 'contact:info answers');
valid_utf8($reply, 'contact:info is valid UTF-8');
contains($reply, "<contact:name>$german{name}</contact:name>", 'contact:info returns the name');
contains($reply, "<contact:street>$german{street}</contact:street>", 'contact:info returns the street');
contains($reply, "<contact:city>$german{city}</contact:city>", 'contact:info returns the city');

# Outside Latin-1: the print path differs once a character no longer fits in one byte
my %polish = (name => 'Łukasz Żółć', street => 'ulica Świętego Ducha 7', city => 'Łódź', sp => 'Łódzkie');
is_code(command_code($sock, update_body($id, postal_info(%polish))), '1000', 'contact:update takes loc beyond Latin-1');
$reply = command_reply($sock, info_body($id));
valid_utf8($reply, 'contact:info is valid UTF-8 after the update');
contains($reply, "<contact:name>$polish{name}</contact:name>", 'contact:update changes the name');
contains($reply, "<contact:sp>$polish{sp}</contact:sp>", 'contact:update changes the state');

# An update that leaves postalInfo alone writes back what it read
is_code(command_code($sock, qq{<update><contact:update $contact_ns><contact:id>$id</contact:id><contact:chg>}
	. qq{<contact:voice>+49.897654321</contact:voice></contact:chg></contact:update></update>}), '1000', 'contact:update of the phone number');
stored_postal($id, 'name', $polish{name}, 'an unrelated update keeps the name intact');

# Scripts without upper case, and names far shorter than Latin ones
for my $case (
	[ 'CJK',      { name => '王小明', street => '千代田1', city => '東京', sp => '東京都' } ],
	[ 'Cyrillic', { name => 'Иван Петров', street => 'улица Ленина 1', city => 'Москва', sp => 'Московская' } ],
	[ 'Greek',    { name => 'Γιώργος', street => 'Οδός Αθηνάς 3', city => 'Αθήνα' } ],
	[ 'Devanagari', { name => 'राजेश कुमार', street => 'गली 12', city => 'दिल्ली' } ],
) {
	my ($script, $fields) = @$case;
	my $cid = new_id();
	is_code(command_code($sock, create_body($cid, postal_info(%$fields))), '1000', "$script loc is accepted");
	contains(command_reply($sock, info_body($cid)), "<contact:name>$fields->{name}</contact:name>", "$script name comes back");
}

# int stays ASCII, and the refusal echoes the value as UTF-8
$reply = command_reply($sock, create_body(new_id(), postal_info(%german, type => 'int')));
is_code(result_code($reply), '2005', 'int still refuses non-ASCII');
valid_utf8($reply, 'the refusal of int is valid UTF-8');
contains($reply, "<contact:name>$german{name}</contact:name>", 'the refusal of int echoes the name');

# What stays invalid in loc
$reply = command_reply($sock, create_body(new_id(), postal_info(%german, name => 'Jörg &lt;Müller&gt;')));
is_code(result_code($reply), '2005', 'loc refuses characters outside the allowed set');
valid_utf8($reply, 'the refusal of loc is valid UTF-8');
is_code(command_code($sock, create_body(new_id(), postal_info(%german, name => '-Jörg'))), '2005', 'loc refuses a leading hyphen');
is_code(command_code($sock, create_body(new_id(), postal_info(%german, city => '7München'))), '2005', 'loc refuses a city starting with a digit');
is_code(command_code($sock, create_body(new_id(), postal_info(%german, sp => 'bayern'))), '2005', 'loc refuses a state in lower case');

# The columns are utf8, three bytes at most: such a name would be cut short or fail in the INSERT
$reply = command_reply($sock, create_body(new_id(), postal_info(%german, name => "\xF0\xA0\xAE\xB7野家")));
is_code(result_code($reply), '2005', 'loc refuses characters beyond the BMP');
valid_utf8($reply, 'the refusal beyond the BMP is valid UTF-8');

# Plain ASCII keeps working in both types
my %ascii = (name => 'John Smith', street => 'Main Street 1', city => 'Springfield', sp => 'Oregon');
is_code(command_code($sock, create_body(new_id(), postal_info(%ascii, type => 'int'), postal_info(%ascii))), '1000', 'ASCII int and loc are accepted');

# clTRID reaches the scripts as bytes, not through the XML parser
my $cltrid = 'tést-' . new_cltrid();
my $svid = new_id();
$reply = command_reply($sock, create_body($svid, postal_info(%german)), $cltrid);
is_code(result_code($reply), '1000', 'a non-ASCII clTRID is accepted');
valid_utf8($reply, 'the reply with a non-ASCII clTRID is valid UTF-8');
contains($reply, "<clTRID>$cltrid</clTRID>", 'a non-ASCII clTRID is echoed unchanged');

# Both frames in the log are UTF-8 as well
my $log = 'FROM `registryTransaction`.`transaction_identifier` WHERE `obj_id` = ? ORDER BY `id` DESC LIMIT 1';
for my $column (qw(clTRIDframe svTRIDframe)) {
	my ($hex) = $dbh->selectrow_array("SELECT HEX(`$column`) $log", undef, $svid);
	my $frame = pack('H*', $hex // '');
	valid_utf8($frame, "$column is valid UTF-8");
	contains($frame, $cltrid, "$column holds the clTRID");
}
my ($frame_hex) = $dbh->selectrow_array("SELECT HEX(`clTRIDframe`) $log", undef, $svid);
contains(pack('H*', $frame_hex // ''), $german{name}, 'clTRIDframe holds the name');

close($sock);
done_testing();
