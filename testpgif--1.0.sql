-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION testpgif" to load this file. \quit

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

WITH p(id,s,sd,t,td,pn) AS (
VALUES	('1'	,'il'	,'u'	,'a'	,'d'	,'a loft ladder')
,	('2'	,'il'	,'d'	,'b'	,'u'	,'a flight of stairs')
,	('3'	,'il'	,'w'	,'s'	,'e'	,NULL)
) INSERT INTO paths(id, src, src_dir, tgt, tgt_dir, path_duration, path_name)
SELECT id,s,sd,t,td,interval '5 minutes',pn
FROM p
UNION ALL
SELECT format('%s''',id),t,td,s,sd,interval '5 minutes',pn
FROM p;

WITH b(id,n,ac,ot) AS (
VALUES	('2'	,'the cellar door'	,true	,'10 minutes')
) INSERT INTO barriers(id, barrier_name, auto_close, opening_time)
SELECT id,n,ac,ot :: interval
FROM b
UNION ALL
SELECT format('%s''',id),n,ac,ot :: interval
FROM b;

--
-- One-way paths
--

INSERT INTO paths(id, src, src_dir, tgt, tgt_dir, path_duration, path_name)
VALUES	('s1'	,'il'	,'ne'	,'b'	,'sw'	,'2 minutes'	,'a downward slide')
;

INSERT INTO objects
VALUES	('w'	,'b'	,'a'	,'bottle'	,'bottle of water')
,	('k'	,'il'	,'the'	,'keys'		,'house keys')
,	('c'	,'il'	,'your'	,'coat'		,'winter coat')
;

CREATE PROCEDURE pgif_init()
LANGUAGE plpgsql
AS $BODY$
BEGIN
	TRUNCATE actions;
	DELETE FROM players;
	INSERT INTO players
	SELECT current_user, 'il', timestamp '1996-07-09 06:22:35 UTC';
END;
$BODY$;
