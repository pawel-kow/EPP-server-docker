# RFC 3915 grace periods. The add, renew, transfer and auto-renew grace periods, the redemption
# period, the deadline for the restore report and the pendingDelete period were hard-coded in
# days (5, 5, 5, 45, 30, 7 and 5), as was the time an expired domain waits for a renewal before
# it goes to redemptionPeriod (30 days). A transfer approved by the cron job, because the losing
# registrar did not answer, did not start transferPeriod. And a
# delete set delTime 30 days ahead. A domain deleted in a test was therefore always purged at
# once, so redemptionPeriod, the restore and pendingDelete could not be reached
# (EPP-server-docker#5). They are now minutes in registry.conf, from the RGP_* variables.
#
# Time is simulated by moving crdate, resTime and delTime back, then running the cron job, so
# the test passes with any configured values. The test stack configures short ones, so that
# the old fixed periods would fail here.

use lib '/var/www/cgi-bin/epp/lib';
use DBI;
use EPP::Config();

my %c = %EPP::Config::c;
my $dbh = DBI->connect("DBI:mysql:$c{mysql_database}:$c{mysql_host}:$c{mysql_port}",
	$c{mysql_username}, $c{mysql_password}, { RaiseError => 1 });

my $domain_ns = 'xmlns:domain="urn:ietf:params:xml:ns:domain-1.0"';
my $rgp_uri = 'urn:ietf:params:xml:ns:rgp-1.0';

my ($tld) = $dbh->selectrow_array('SELECT `tld` FROM `domain_tld` LIMIT 1');
$tld =~ s/^\.//;
$tld = lc($tld);

my %minutes;
for my $key (qw(rgp_add_period_minutes rgp_renew_period_minutes rgp_transfer_period_minutes rgp_auto_renew_period_minutes
		rgp_expiry_grace_minutes rgp_redemption_period_minutes rgp_pending_restore_minutes rgp_pending_delete_minutes)) {
	my $v = $c{$key};
	is_code((defined $v && $v =~ /^\d+$/) ? 'a number' : ($v // 'unset'), 'a number', "registry.conf sets $key");
	$minutes{$key} = (defined $v && $v =~ /^\d+$/) ? $v : 0;
}
my $add = $minutes{rgp_add_period_minutes};
my $redemption = $minutes{rgp_redemption_period_minutes};
my $restore = $minutes{rgp_pending_restore_minutes};
my $pending_delete = $minutes{rgp_pending_delete_minutes};

my $sock = epp_session(clid => 'foo', pw => 'bar', exturis => [$rgp_uri]);

my $domain_seq = 0;
sub new_domain { return lc(sprintf('rgp-%d-%d-%d.%s', time(), $$, ++$domain_seq, $tld)); }

sub create_code {
	my ($name) = @_;
	return command_code($sock, qq{<create><domain:create $domain_ns><domain:name>$name</domain:name>}
		. q{<domain:period unit="y">1</domain:period><domain:authInfo><domain:pw>Secret123</domain:pw></domain:authInfo>}
		. q{</domain:create></create>});
}

sub delete_code {
	my ($name) = @_;
	return command_code($sock, qq{<delete><domain:delete $domain_ns><domain:name>$name</domain:name></domain:delete></delete>});
}

sub restore_code {
	my ($name, $op) = @_;
	my $report = $op eq 'report'
		? q{<rgp:report><rgp:preData>Pre-delete data</rgp:preData><rgp:postData>Post-restore data</rgp:postData>}
			. q{<rgp:delTime>2026-01-01T00:00:00.0Z</rgp:delTime><rgp:resTime>2026-01-02T00:00:00.0Z</rgp:resTime>}
			. q{<rgp:resReason>Registrant error.</rgp:resReason><rgp:statement>True.</rgp:statement>}
			. q{<rgp:statement>Acknowledged.</rgp:statement></rgp:report>}
		: '';
	return command_code($sock, qq{<update><domain:update $domain_ns><domain:name>$name</domain:name><domain:chg/></domain:update></update>}
		. qq{<extension><rgp:update xmlns:rgp="$rgp_uri"><rgp:restore op="$op">$report</rgp:restore></rgp:update></extension>});
}

# "<rgpStatus> <domain:status ...>" from domain:info, the result code when it is not 1000
sub state {
	my ($name) = @_;
	my $reply = command_reply($sock, qq{<info><domain:info $domain_ns><domain:name>$name</domain:name></domain:info></info>});
	my $code = result_code($reply);
	return $code // 'no reply' unless defined $code && $code eq '1000';
	my ($rgp) = $reply =~ m{<rgp:rgpStatus\s+s="([^"]*)"};
	my @status = sort ($reply =~ m{<domain:status\s+s="([^"]+)"}g);
	return join(' ', ($rgp // '(none)'), @status);
}

sub run_cron { system('perl -I/var/www/cgi-bin/epp/lib /var/www/cgi-bin/epp/cron/change-domain-status.pl >/dev/null 2>&1'); }

# Moves a timestamp column of the domain back by the given number of minutes from now
sub set_minutes_ago {
	my ($name, $column, $ago) = @_;
	$dbh->do("UPDATE `domain` SET `$column` = DATE_SUB(NOW(), INTERVAL ? MINUTE) WHERE `name` = ?", undef, $ago, uc($name));
}

# Inside the add grace period a delete purges the domain at once
my $early = new_domain();
is_code(create_code($early), 1000, 'create');
is_code(state($early), 'addPeriod ok', 'a new domain is in addPeriod');
is_code(delete_code($early), 1001, 'delete inside the add grace period');
is_code(state($early), 2303, 'a delete inside the add grace period purges the domain');

# After it, the delete starts the redemption period
my $name = new_domain();
is_code(create_code($name), 1000, 'create');
set_minutes_ago($name, 'crdate', $add + 1);
is_code(delete_code($name), 1001, 'delete after the add grace period');
is_code(state($name), 'redemptionPeriod pendingDelete', 'a delete after the add grace period starts redemptionPeriod');
my ($deltime_now) = $dbh->selectrow_array('SELECT ABS(TIMESTAMPDIFF(MINUTE, `delTime`, NOW())) <= 1 FROM `domain` WHERE `name` = ?', undef, uc($name));
is_code($deltime_now, 1, 'delTime is the time of the delete');
run_cron();
is_code(state($name), 'redemptionPeriod pendingDelete', 'the cron job keeps a fresh delete in redemptionPeriod');

# The cron job also ends addPeriod once the add grace period is over
my $aged = new_domain();
is_code(create_code($aged), 1000, 'create');
set_minutes_ago($aged, 'crdate', $add + 1);
run_cron();
is_code(state($aged), '(none) ok', 'the cron job ends addPeriod after the add grace period');

# Restore request, then the report deadline passes
is_code(restore_code($name, 'request'), 1000, 'restore request in redemptionPeriod');
is_code(state($name), 'pendingRestore pendingDelete', 'a restore request sets pendingRestore');
run_cron();
is_code(state($name), 'pendingRestore pendingDelete', 'the cron job keeps a fresh pendingRestore');
set_minutes_ago($name, 'resTime', $restore + 1);
run_cron();
is_code(state($name), 'redemptionPeriod pendingDelete', 'without a report in time the domain returns to redemptionPeriod');

# Restore request and report
is_code(restore_code($name, 'request'), 1000, 'second restore request');
is_code(restore_code($name, 'report'), 1000, 'restore report');
is_code(state($name), '(none) ok', 'the report restores the domain');

# The redemption period ends in pendingDelete, which ends in the purge
my $gone = new_domain();
is_code(create_code($gone), 1000, 'create');
set_minutes_ago($gone, 'crdate', $add + 1);
is_code(delete_code($gone), 1001, 'delete after the add grace period');
set_minutes_ago($gone, 'delTime', $redemption + 1);
run_cron();
is_code(state($gone), 'pendingDelete pendingDelete', 'after the redemption period the domain is pendingDelete');
is_code(restore_code($gone, 'request'), 2304, 'no restore in pendingDelete');
run_cron();
is_code(state($gone), 'pendingDelete pendingDelete', 'the cron job keeps the domain during pendingDelete');
set_minutes_ago($gone, 'delTime', $redemption + $pending_delete + 1);
run_cron();
is_code(state($gone), 2303, 'after pendingDelete the domain is purged');

# The renew, transfer and auto-renew grace periods. Each is entered by seeding the domain row:
# auto-renew is switched off in change-domain-status.pl, and a transfer needs a second session.
# A delete inside such a period credits the registrar, which leaves a payment_history row.
sub seed_grace {
	my ($name, $status, $column, $ago) = @_;
	$dbh->do("UPDATE `domain` SET `rgpstatus` = ?, `$column` = DATE_SUB(NOW(), INTERVAL ? MINUTE),"
		. " `renewPeriod` = 12, `autoRenewPeriod` = 12, `transferPeriod` = 12 WHERE `name` = ?", undef, $status, $ago, uc($name));
}

sub credits {
	my ($name, $status) = @_;
	my ($n) = $dbh->selectrow_array('SELECT COUNT(*) FROM `payment_history` WHERE `description` LIKE ?',
		undef, "%during grace $status,%domain $name %");
	return $n;
}

for my $grace (['renewPeriod', 'renewedDate', $minutes{rgp_renew_period_minutes}],
		['transferPeriod', 'trdate', $minutes{rgp_transfer_period_minutes}],
		['autoRenewPeriod', 'renewedDate', $minutes{rgp_auto_renew_period_minutes}]) {
	my ($status, $column, $period) = @$grace;

	my $kept = new_domain();
	is_code(create_code($kept), 1000, "create for $status");
	seed_grace($kept, $status, $column, $period > 1 ? $period - 1 : 0);
	run_cron();
	is_code(state($kept), "$status ok", "the cron job keeps $status before its end");
	seed_grace($kept, $status, $column, $period + 1);
	run_cron();
	is_code(state($kept), '(none) ok', "the cron job ends $status after $column plus its period");

	my $inside = new_domain();
	is_code(create_code($inside), 1000, "create for a delete in $status");
	seed_grace($inside, $status, $column, 0);
	is_code(delete_code($inside), 1001, "delete inside $status");
	is_code(credits($inside, $status), 1, "a delete inside $status credits the registrar");
	is_code(state($inside), 'redemptionPeriod pendingDelete', "a delete inside $status starts redemptionPeriod");

	my $after = new_domain();
	is_code(create_code($after), 1000, "create for a delete after $status");
	seed_grace($after, $status, $column, $period + 1);
	is_code(delete_code($after), 1001, "delete after $status, before the cron job ends it");
	is_code(credits($after, $status), 0, "a delete after $status gives no credit");
}

# An expired domain that is not renewed goes to redemptionPeriod after the expiry grace
my $expiry = $minutes{rgp_expiry_grace_minutes};
my $expired = new_domain();
is_code(create_code($expired), 1000, 'create for expiry');
$dbh->do("UPDATE `domain` SET `rgpstatus` = NULL, `exdate` = DATE_SUB(NOW(), INTERVAL ? MINUTE) WHERE `name` = ?",
	undef, $expiry > 1 ? $expiry - 1 : 0, uc($expired));
run_cron();
is_code(state($expired), '(none) ok', 'the cron job keeps an expired domain during the expiry grace');
set_minutes_ago($expired, 'exdate', $expiry + 1);
run_cron();
is_code(state($expired), 'redemptionPeriod pendingDelete', 'after the expiry grace the domain is in redemptionPeriod');
my ($deltime_end) = $dbh->selectrow_array('SELECT ABS(TIMESTAMPDIFF(MINUTE, `delTime`, DATE_ADD(`exdate`, INTERVAL ? MINUTE))) = 0 FROM `domain` WHERE `name` = ?',
	undef, $expiry, uc($expired));
is_code($deltime_end, 1, 'delTime is the end of the expiry grace');

# A transfer that the cron job approves starts transferPeriod, as one the losing registrar approves does
my $moved = new_domain();
is_code(create_code($moved), 1000, 'create for transfer');
my $gaining = epp_session(clid => 'baz', pw => 'qux', exturis => [$rgp_uri]);
is_code(command_code($gaining, qq{<transfer op="request"><domain:transfer $domain_ns><domain:name>$moved</domain:name>}
	. q{<domain:period unit="y">1</domain:period><domain:authInfo><domain:pw>Secret123</domain:pw></domain:authInfo>}
	. q{</domain:transfer></transfer>}), 1001, 'transfer request');
$dbh->do('UPDATE `domain` SET `acdate` = DATE_SUB(NOW(), INTERVAL 1 MINUTE) WHERE `name` = ?', undef, uc($moved));
system('perl -I/var/www/cgi-bin/epp/lib /var/www/cgi-bin/epp/cron/auto-approve-transfer.pl >/dev/null 2>&1');
my ($trstatus, $transfer_period) = $dbh->selectrow_array('SELECT `trstatus`, `transferPeriod` FROM `domain` WHERE `name` = ?', undef, uc($moved));
is_code($trstatus // 'NULL', 'serverApproved', 'the cron job approves the transfer');
is_code($transfer_period // 'NULL', 12, 'the approved transfer records its period');
my $info = command_reply($gaining, qq{<info><domain:info $domain_ns><domain:name>$moved</domain:name></domain:info></info>}) // '';
my ($moved_rgp) = $info =~ m{<rgp:rgpStatus\s+s="([^"]*)"};
is_code($moved_rgp // '(none)', 'transferPeriod', 'a transfer approved by the cron job starts transferPeriod');
is_code(command_code($gaining, qq{<delete><domain:delete $domain_ns><domain:name>$moved</domain:name></domain:delete></delete>}), 1001,
	'the gaining registrar deletes inside transferPeriod');
is_code(credits($moved, 'transferPeriod'), 1, 'a delete inside the transferPeriod of an approved transfer credits the registrar');
close($gaining);

close($sock);
done_testing();
