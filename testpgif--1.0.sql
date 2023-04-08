-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION testpgif" to load this file. \quit

TRUNCATE object_metadata CASCADE;

--
-- Initial state
--

CREATE PROCEDURE pgif_init()
LANGUAGE plpgsql
AS $BODY$
BEGIN
	TRUNCATE actions
	, object_state
	, barrier_state;
	INSERT INTO object_state(id)
	  SELECT id FROM object_metadata;
	INSERT INTO barrier_state(id)
	  SELECT id FROM barrier_metadata;
END;
$BODY$;

--
-- Locations
--

INSERT INTO locations (id, description) VALUES
('inlo'	,'the Initial Location'),
('abo'	,'the Above'),
('bel'	,'the Below'),
('sid'	,'the Side')
;

--
-- Two-way paths
--

INSERT INTO paths(id, src, src_dir, tgt, tgt_dir, path_name)
VALUES	('1'	,'inlo'	,'u'	,'abo'	,'d'	,'a loft ladder')
,	('2'	,'inlo'	,'d'	,'bel'	,'u'	,'a flight of stairs')
,	('3'	,'inlo'	,'w'	,'sid'	,'e'	,NULL)
;

INSERT INTO barriers(id, barrier_name, auto_close, opening_time)
VALUES	('2'	,'the cellar door'	,true	,'10 minutes')
;

--
-- One-way paths
--

INSERT INTO paths(id, src, src_dir, tgt, path_duration, path_name)
VALUES	('dosl'	,'inlo'	,'ne'	,'bel'	,'2 minutes'	,'a downward slide')
;

--
-- Characters
--

INSERT INTO characters (id, name, location, is_opaque, own_time)
SELECT
  'you'
, 'you'
, 'inlo'
, true
, timestamp '1996-07-09 06:22:35 UTC'
;

--
-- Objects
--

INSERT INTO objects(id, location, article, name)
VALUES	('phone'	,'you'		,'your'	,'mobile phone')
,	('bottle'	,'bel'		,'a'	,'bottle of water')
,	('keys'		,'inlo'		,'the'	,'house keys')
,	('coat'		,'inlo'		,'your'	,'winter coat')
;
