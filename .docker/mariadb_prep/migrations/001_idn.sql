-- EPP IDN extension, urn:ietf:params:xml:ns:idn-1.0 (pawel-kow/epp#26)
--
-- Safe to run more than once, so it can also be applied to an existing database.
-- Each idn_table row is an IDN table that idn:table may name. `codepoints` lists the
-- code points a label may use, as hex values and ranges separated by spaces, for example
-- "002D 0030-0039 0061-007A 00E4". Include the ASCII letters, digits and the hyphen.

CREATE TABLE IF NOT EXISTS `registry`.`idn_table` (
	`id` int(10) unsigned NOT NULL AUTO_INCREMENT,
	`tag` varchar(32) NOT NULL,
	`description` varchar(255) default NULL,
	`codepoints` text NOT NULL,
	PRIMARY KEY (`id`),
	UNIQUE KEY `tag` (`tag`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COMMENT='IDN tables';

ALTER TABLE `registry`.`domain`
	ADD COLUMN IF NOT EXISTS `idn_table` varchar(32) default NULL AFTER `idnlang`,
	ADD COLUMN IF NOT EXISTS `idn_uname` varchar(255) default NULL AFTER `idn_table`;

INSERT IGNORE INTO `registry`.`idn_table` (`tag`,`description`,`codepoints`) VALUES
	('de', 'German', '002D 0030-0039 0061-007A 00DF 00E4 00F6 00FC'),
	('es', 'Spanish', '002D 0030-0039 0061-007A 00E1 00E9 00ED 00F1 00F3 00FA 00FC');
