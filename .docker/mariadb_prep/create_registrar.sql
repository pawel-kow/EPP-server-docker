DELETE FROM registry.domain_price;
DELETE FROM registry.domain_restore_price;
DELETE FROM registry.domain_tld;
DELETE FROM registry.registrar;

INSERT INTO registry.registrar (name,clid,pw,prefix,email,whois_server,url,abuse_email,abuse_phone,accountBalance,creditLimit,creditThreshold,thresholdType,crdate) VALUES
	 ('<REG1_NAME>','<REG1_ID>','<REG1_PWD_HASH>','<REG1_PREFIX>','<REG1_EMAIL>','<REG1_WHOIS>','<REG1_URL>','<REG1_ABUSE_EMAIL>','<REG1_ABUSE_PHONE>',<REG1_ACCOUNT_BALANCE>,<REG1_CREDIT_LIMIT>,<REG1_CREDIT_THRESHHOLD>,'fixed','<REG_CR_DATE>'),
	 ('<REG2_NAME>','<REG2_ID>','<REG2_PWD_HASH>','<REG2_PREFIX>','<REG2_EMAIL>','<REG2_WHOIS>','<REG2_URL>','<REG2_ABUSE_EMAIL>','<REG2_ABUSE_PHONE>',<REG2_ACCOUNT_BALANCE>,<REG2_CREDIT_LIMIT>,<REG2_CREDIT_THRESHHOLD>,'fixed','<REG_CR_DATE>');

INSERT INTO registry.domain_tld
(tld)
VALUES('.<REGISTRY_TLD>');

SET @tld_id = LAST_INSERT_ID();

INSERT INTO registry.domain_price
(tldid, command, m0, m12, m24, m36, m48, m60, m72, m84, m96, m108, m120)
VALUES(@tld_id, 'create', 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00);
INSERT INTO registry.domain_price
(tldid, command, m0, m12, m24, m36, m48, m60, m72, m84, m96, m108, m120)
VALUES(@tld_id, 'renew', 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00);
INSERT INTO registry.domain_price
(tldid, command, m0, m12, m24, m36, m48, m60, m72, m84, m96, m108, m120)
VALUES(@tld_id, 'transfer', 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00);

INSERT INTO registry.domain_restore_price
(tldid, price)
VALUES(@tld_id, 0.00);
