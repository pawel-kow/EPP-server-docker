# Minimal EPP client and assertions for test/*.t. Prepended to each test by test/run.sh.
# Uses only core Perl, because it runs inside the epp-server container.
use strict;
use warnings;
use IO::Socket::INET;

my $REPLY_TIMEOUT = 15;
my $CONNECT_TIMEOUT = 60;
my ($passed, $failed, $trid_seq) = (0, 0, 0);

# Unique per run: the server keeps every clTRID and refuses a reused one
sub new_cltrid { return sprintf('t-%d-%d-%d', time(), $$, ++$trid_seq); }

sub read_exact {
	my ($sock, $len) = @_;
	my $buf = '';
	while (length($buf) < $len) {
		my $n = sysread($sock, $buf, $len - length($buf), length($buf));
		return undef unless $n;
	}
	return $buf;
}

# Returns the frame, or undef when the server closes the connection or stays silent
sub read_frame {
	my ($sock) = @_;
	my $frame;
	eval {
		local $SIG{ALRM} = sub { die "timeout\n" };
		alarm($REPLY_TIMEOUT);
		my $header = read_exact($sock, 4);
		$frame = read_exact($sock, unpack('N', $header) - 4) if defined $header;
		alarm(0);
	};
	alarm(0);
	return $frame;
}

sub send_frame {
	my ($sock, $xml) = @_;
	print {$sock} pack('N', length($xml) + 4) . $xml;
}

# Opens a session and consumes the greeting. Retries while Apache is still starting.
# In list context also returns the greeting frame.
sub epp_connect {
	my $deadline = time() + $CONNECT_TIMEOUT;
	while (time() < $deadline) {
		my $sock = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => 700, Proto => 'tcp');
		if ($sock) {
			$sock->autoflush(1);
			my $greeting = read_frame($sock);
			return wantarray ? ($sock, $greeting) : $sock if defined $greeting;
			close($sock);
		}
		sleep(1);
	}
	die "no EPP greeting on 127.0.0.1:700 after ${CONNECT_TIMEOUT}s\n";
}

sub login_frame {
	my (%a) = @_;
	my @uris = @{ $a{objuris} || [map { "urn:ietf:params:xml:ns:$_-1.0" } qw(domain contact host)] };
	my $svcs = join('', map { "<objURI>$_</objURI>" } @uris);
	if ($a{exturis} && @{ $a{exturis} }) {
		$svcs .= '<svcExtension>' . join('', map { "<extURI>$_</extURI>" } @{ $a{exturis} }) . '</svcExtension>';
	}
	return qq{<?xml version="1.0" encoding="UTF-8" standalone="no"?>}
		. qq{<epp xmlns="urn:ietf:params:xml:ns:epp-1.0"><command><login>}
		. qq{<clID>$a{clid}</clID><pw>$a{pw}</pw>}
		. qq{<options><version>1.0</version><lang>en</lang></options>}
		. qq{<svcs>$svcs</svcs></login><clTRID>$a{cltrid}</clTRID></command></epp>};
}

sub result_code {
	my ($reply) = @_;
	return undef unless defined $reply;
	return $reply =~ /<result\s+code="(\d+)"/ ? $1 : "unparsable reply: $reply";
}

# Logs in on a new connection. Returns the reply frame, or undef when there is no reply.
sub login_reply {
	my (%a) = @_;
	$a{cltrid} //= new_cltrid();
	my $sock = epp_connect();
	send_frame($sock, login_frame(%a));
	my $reply = read_frame($sock);
	close($sock);
	return $reply;
}

# The greeting the server sends on a new connection
sub greeting_frame {
	my ($sock, $greeting) = epp_connect();
	close($sock);
	return $greeting;
}

# As login_reply, but returns the result code
sub login_code { return result_code(login_reply(@_)); }

# Logs in and returns the open socket. Dies when the login does not answer 1000.
sub epp_session {
	my (%a) = @_;
	my $sock = epp_connect();
	send_frame($sock, login_frame(%a, cltrid => new_cltrid()));
	my $code = result_code(read_frame($sock));
	die "login as $a{clid} answered " . ($code // 'nothing') . "\n" unless defined $code && $code eq '1000';
	return $sock;
}

# Sends the inside of <command> and returns the reply frame, or undef when there is no reply.
# A fresh clTRID is used unless one is given.
sub command_reply {
	my ($sock, $body, $cltrid) = @_;
	$cltrid //= new_cltrid();
	send_frame($sock, qq{<?xml version="1.0" encoding="UTF-8" standalone="no"?>}
		. qq{<epp xmlns="urn:ietf:params:xml:ns:epp-1.0"><command>$body<clTRID>$cltrid</clTRID></command></epp>});
	return read_frame($sock);
}

# As command_reply, but returns the result code
sub command_code { return result_code(command_reply(@_)); }

# As command_reply, but the frame carries no clTRID
sub command_reply_without_cltrid {
	my ($sock, $body) = @_;
	send_frame($sock, qq{<?xml version="1.0" encoding="UTF-8" standalone="no"?>}
		. qq{<epp xmlns="urn:ietf:params:xml:ns:epp-1.0"><command>$body</command></epp>});
	return read_frame($sock);
}

sub is_code {
	my ($got, $want, $name) = @_;
	if (defined $got && $got eq $want) {
		$passed++;
		print "ok - $name\n";
	} else {
		$failed++;
		print "not ok - $name: expected $want, got " . ($got // 'no reply') . "\n";
	}
}

sub done_testing {
	print "$passed passed, $failed failed\n";
	exit($failed ? 1 : 0);
}

