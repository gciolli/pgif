-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION testpgif" to load this file. \quit

CREATE PROCEDURE testpgif(text)
LANGUAGE plpgsql
AS $BODY$
BEGIN
	CALL pgif($1);
END;
$BODY$;

TRUNCATE objects, paths, containers CASCADE;

INSERT INTO locations VALUES
('il'	,'the initial location'),
('a'	,'the Above'),
('b'	,'the Below'),
('s'	,'the Side')
;

--
-- Two-way paths
--

WITH p(s,sd,t,td,pn) AS (
VALUES	('il'	,'u'	,'a'	,'d'	,'a loft ladder')
,	('il'	,'d'	,'b'	,'u'	,'a flight of stairs')
,	('il'	,'w'	,'s'	,'e'	,NULL)
) INSERT INTO paths(src, src_dir, tgt, tgt_dir, path_duration, path_name)
SELECT s,sd,t,td,interval '5 minutes',pn
FROM p
UNION ALL
SELECT t,td,s,sd,interval '5 minutes',pn
FROM p;

--
-- One-way paths
--

INSERT INTO paths(src, src_dir, tgt, tgt_dir, path_duration, path_name)
VALUES	('il'	,'ne'	,'b'	,'sw'	,'2 minutes'	,'a downward slide')
;

INSERT INTO objects VALUES
('w'	,'b'	,'a'	,'bottle'	,'bottle of water'),
('k'	,'il'	,'the'	,'keys'		,'house keys')
;

INSERT INTO players
SELECT current_user, 'il', timestamp '1996-07-09 06:22:35 UTC';
