-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION testpgif" to load this file. \quit

TRUNCATE instances, paths CASCADE;

--
-- Initial state
--

CREATE PROCEDURE pgif_init()
LANGUAGE plpgsql
AS $BODY$
BEGIN
	TRUNCATE actions;
	DELETE FROM characters;
	INSERT INTO characters
	( id
	, name
	, current_location
	, is_opaque
	, own_time
	) SELECT
	  current_user
	, current_user
	, 'il'
	, true
	, timestamp '1996-07-09 06:22:35 UTC'
	;
END;
$BODY$;

--
-- Locations
--

INSERT INTO locations (id, article, name) VALUES
('il'	,'the'	,'initial location'),
('a'	,'the'	,'Above'),
('b'	,'the'	,'Below'),
('s'	,'the'	,'Side')
;

--
-- Two-way paths
--

INSERT INTO paths(id, src, src_dir, tgt, tgt_dir, path_name)
VALUES	('1'	,'il'	,'u'	,'a'	,'d'	,'a loft ladder')
,	('2'	,'il'	,'d'	,'b'	,'u'	,'a flight of stairs')
,	('3'	,'il'	,'w'	,'s'	,'e'	,NULL)
;

INSERT INTO barriers(id, barrier_name, auto_close, opening_time)
VALUES	('2'	,'the cellar door'	,true	,'10 minutes')
;

--
-- One-way paths
--

INSERT INTO paths(id, src, src_dir, tgt, path_duration, path_name)
VALUES	('s1'	,'il'	,'ne'	,'b'	,'2 minutes'	,'a downward slide')
;

--
-- Objects
--

INSERT INTO objects(id, current_location, article, name)
VALUES	('bottle'	,'b'	,'a'	,'bottle of water')
,	('keys'		,'il'	,'the'	,'house keys')
,	('coat'		,'il'	,'your'	,'winter coat')
;
