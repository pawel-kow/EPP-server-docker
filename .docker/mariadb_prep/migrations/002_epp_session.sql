-- Services chosen at EPP login, RFC 5730 section 2.9.3.1 (pawel-kow/epp#27)
--
-- Safe to run more than once, so it can also be applied to an existing database.
-- mod_epp runs every frame as its own CGI request, and sends the same `session` cookie with
-- each request of a connection. session-login.cgi stores the objURI and extURI lists here under
-- that cookie, every command reads them back, and session-logout.cgi removes the row.
-- clean-epp-sessions.pl removes rows left by clients that disconnected without <logout>.

CREATE TABLE IF NOT EXISTS `registry`.`epp_session` (
	`session` varchar(64) NOT NULL,
	`registrar_id` int(10) unsigned NOT NULL,
	`objuris` text NOT NULL,
	`exturis` text NOT NULL,
	`logged_in` datetime NOT NULL,
	`last_used` datetime NOT NULL,
	PRIMARY KEY (`session`),
	KEY `last_used` (`last_used`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COMMENT='EPP sessions and the services chosen at login';
