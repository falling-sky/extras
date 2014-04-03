DROP TABLE IF EXISTS `stats`;
DROP TABLE IF EXISTS `survey`;
CREATE TABLE `survey` (
  `cookie` char(80) character set latin1 default NULL,
  `ip` char(40) character set latin1 NOT NULL,
  `ip4` char(40) character set latin1 default NULL,
  `ip6` char(40) character set latin1 default NULL,
  `status_a` enum('ok','slow','bad','timeout') character set latin1 NOT NULL,
  `status_aaaa` enum('ok','slow','bad','timeout') character set latin1 NOT NULL,
  `status_ds4` enum('ok','slow','bad','timeout') character set latin1 NOT NULL,
  `status_ds6` enum('ok','slow','bad','timeout') character set latin1 NOT NULL,
  `status_ipv4` enum('ok','slow','bad','timeout') character set latin1 NOT NULL,
  `status_ipv6` enum('ok','slow','bad','timeout') character set latin1 NOT NULL,
  `status_dsmtu` enum('ok','slow','bad','timeout','unknown') NOT NULL,
  `time_a` mediumint(8) unsigned default NULL,
  `time_aaaa` mediumint(8) unsigned default NULL,
  `time_ds4` mediumint(8) unsigned default NULL,
  `time_ds6` mediumint(8) unsigned default NULL,
  `time_ipv4` mediumint(8) unsigned default NULL,
  `time_ipv6` mediumint(8) unsigned default NULL,
  `time_dsmtu` mediumint(8) unsigned default NULL,
  `tokens` char(200) character set latin1 default NULL,
  `timestamp` timestamp NOT NULL default CURRENT_TIMESTAMP,
  `ua_id` int(11) default NULL,
  `status_v6ns` enum('ok','slow','bad','timeout') character set latin1 NOT NULL,
  `time_v6ns` mediumint(8) unsigned default NULL,
  `ix` bigint(20) unsigned NOT NULL auto_increment,
  `status_v6mtu` enum('ok','slow','bad','timeout') character set latin1 default NULL,
  `time_v6mtu` mediumint(8) unsigned default NULL,
  PRIMARY KEY  (`ix`),
  KEY `status_a` (`status_a`),
  KEY `status_aaaa` (`status_aaaa`),
  KEY `status_ds4` (`status_ds4`),
  KEY `status_ds6` (`status_ds6`),
  KEY `status_ipv4` (`status_ipv4`),
  KEY `status_ipv6` (`status_ipv6`),
  KEY `timestamp` (`timestamp`),
  KEY `status_v6mtu` (`status_v6mtu`)
) ENGINE=MyISAM AUTO_INCREMENT=220869 DEFAULT CHARSET=utf8;
                                                                  
DROP TABLE IF EXISTS `user_agent`;
DROP TABLE IF EXISTS `user_agents`;
CREATE TABLE `user_agents` (
  `id` int(11) NOT NULL auto_increment,
  `user_agent` varchar(255) character set latin1 NOT NULL,
  UNIQUE KEY `user_agent` (`user_agent`),
  UNIQUE KEY `id` (`id`)
) ENGINE=MyISAM AUTO_INCREMENT=23798 DEFAULT CHARSET=utf8;


DROP TABLE IF EXISTS `daily_summary`;
CREATE TABLE `daily_summary` (
  `datestamp` date NOT NULL,
  `total` int(10) unsigned default NULL,
  `tokens` char(200) character set latin1 default NULL,
  KEY `datestamp` (`datestamp`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;

DROP TABLE IF EXISTS `monthly_summary`;
CREATE TABLE `monthly_summary` (
  `datestamp` date NOT NULL,
  `total` int(10) unsigned default NULL,
  `tokens` char(200) character set latin1 default NULL,
  KEY `datestamp` (`datestamp`)
) ENGINE=MyISAM DEFAULT CHARSET=utf8;
