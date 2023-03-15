-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgif" to load this file. \quit

--
-- Basic IF data types
--

CREATE TYPE action AS
( verb text
, words text[]
, sentence text
, response text
, duration interval
);

CREATE TABLE directions
( id text PRIMARY KEY
, format text not null
, description text
);

INSERT INTO directions VALUES
( 'n'	,'towards %s'	,'north')
,('ne'	,'towards %s'	,'north-east')
,('e'	,'towards %s'	,'east')
,('se'	,'towards %s'	,'south-east')
,('s'	,'towards %s'	,'south')
,('sw'	,'towards %s'	,'south-west')
,('w'	,'towards %s'	,'west')
,('nw'	,'towards %s'	,'north-west')
,('u'	,'going above'	,'up')
,('d'	,'going below'	,'down')
;

--
-- IF tables
--

CREATE TABLE locations
( id text PRIMARY KEY
, title text NOT NULL
, description text
);

CREATE TABLE paths
( src     text REFERENCES locations(id)
, src_dir text REFERENCES directions(id)
, tgt     text REFERENCES locations(id)
, tgt_dir text REFERENCES directions(id)
, path_name text
, path_duration interval
, PRIMARY KEY (src, src_dir, tgt, tgt_dir)
);

CREATE TABLE objects
( id text PRIMARY KEY
, location text REFERENCES locations(id)
, article text NOT NULL
, title text NOT NULL
, description text
);

CREATE TABLE players
( user_name name PRIMARY KEY
, current_place text NOT NULL REFERENCES locations(id)
, user_time timestamp(0) NOT NULL
);

--
-- IF utilities
--

CREATE FUNCTION pgif_time()
RETURNS text
LANGUAGE SQL
AS $BODY$
SELECT format('%s %s %s %s'
, trim(to_char(user_time, 'Day'))
, regexp_replace(to_char(user_time, 'DD'), '^0', '')
, trim(to_char(user_time, 'Month'))
, to_char(user_time, 'YYYY, HH12:MI am'))
FROM players
WHERE user_name = current_user
$BODY$;

CREATE FUNCTION pgif_format(text)
RETURNS text
LANGUAGE SQL
AS $BODY$
SELECT format(E'\n%s\n\n> ', $1)
$BODY$;

CREATE FUNCTION expand_abbreviation(text)
RETURNS text
LANGUAGE SQL
AS $BODY$
SELECT CASE $1
WHEN 'H'  THEN 'HELP'
WHEN 'I'  THEN 'INVENTORY'
WHEN 'L'  THEN 'LOOK'
WHEN 'Q'  THEN 'QUIT'
ELSE $1
END CASE
$BODY$;

--
-- IF actions
--

CREATE FUNCTION do_look()
RETURNS text
LANGUAGE plpgsql
AS $BODY$
DECLARE
	x text;
	y text;
	z text;
BEGIN
	-- (1) description
	SELECT format('You are in %s.', coalesce(description, title))
	INTO STRICT x
	FROM locations l
	, players u
	WHERE l.id = u.current_place
	AND u.user_name = current_user;
	-- (2) named exits
	SELECT string_agg
	( format
	  ( 'There is %s %s.'
	  , p.path_name
	  , format(d.format, d.description)
	  ), E'\n')
	INTO y
	FROM players u
	, paths p
	, directions d
	WHERE u.user_name = current_user
	AND p.src = u.current_place
	AND p.src_dir = d.id
	AND p.path_name IS NOT NULL;
	-- (3) anonymous exits
	SELECT string_agg(d.description, ', ')
	INTO z
	FROM players u
	, paths p
	, directions d
	WHERE u.user_name = current_user
	AND p.src = u.current_place
	AND p.src_dir = d.id
	AND p.path_name IS NULL;
	--
	RETURN format
	( E'--[%s]--\n%s\n%s\n%s.'
	, pgif_time()
	, x
	, y
	, CASE WHEN z IS NULL
	  THEN 'No other exits available'
	  ELSE format('Other exits: %s', z)
	  END
	);
END;
$BODY$;

CREATE PROCEDURE do_move(a INOUT action)
LANGUAGE plpgsql
AS $BODY$
DECLARE
	x text;
	y text;
	z interval;
BEGIN
	SELECT description
	INTO STRICT y
	FROM directions
	WHERE upper(a.words[1]) = upper(id);
	SELECT p.tgt, p.path_duration
	INTO x, z
	FROM players u
	JOIN paths p
	  ON p.src = u.current_place
	 AND upper(p.src_dir) = upper(a.words[1])
	WHERE u.user_name = current_user;
	IF FOUND THEN
		UPDATE players
		SET current_place = x
		, user_time = user_time + z
		WHERE user_name = current_user;
		a.response := format(E'Moving %s.\n\n%s', y, do_look());
	ELSE
		a.response := format(E'Cannot move %s.', y);
	END IF;
END;
$BODY$;

CREATE FUNCTION do_inventory()
RETURNS text
LANGUAGE plpgsql
AS $BODY$
BEGIN
	RETURN 'Apologies: INVENTORY not yet implemented.';
END;
$BODY$;

CREATE PROCEDURE do_say(a INOUT action)
LANGUAGE plpgsql
AS $BODY$
BEGIN
	a.response := 'Apologies: SAY not yet implemented.';
END;
$BODY$;

--
-- IF engine
--

CREATE FUNCTION parse(text)
RETURNS action
LANGUAGE plpgsql
AS $BODY$
DECLARE
	a action;
	words text[];
BEGIN
	-- (1) sanitise input
	a.sentence := regexp_replace($1, '"', ' " ', 'g');
	a.sentence := regexp_replace(a.sentence, '	', ' ', 'g');
	a.sentence := regexp_replace(a.sentence, '  +', ' ', 'g');

	-- (2) split in words
	words := string_to_array(upper(trim(a.sentence)), ' ');
	IF words[1:1] <@ '{N,S,E,W,NE,SE,SW,NW,U,D}' THEN
		a.verb := 'MOVE';
		a.words := words[1:1];
	ELSE
		a.verb := expand_abbreviation(words[1]);
		a.words := words[2:];
	END IF;

	RETURN a;
END;
$BODY$;

CREATE PROCEDURE effect(a INOUT action)
LANGUAGE plpgsql
AS $BODY$
BEGIN
	a.duration := '0 minutes';
	CASE a.verb
	--
	-- Read-only actions
	--
	WHEN 'HELP' THEN
		a.duration := '3 minutes';
		a.response := do_help();
	WHEN 'LOOK' THEN
		a.duration := '3 minutes';
		a.response := do_look();
	WHEN 'QUIT' THEN
		NULL;
	WHEN 'INVENTORY' THEN
		a.response := do_inventory();
	--
	-- Write actions
	--
	WHEN 'SAY' THEN
		CALL do_say(a);
	WHEN 'MOVE' THEN
		CALL do_move(a);
	--
	-- None of the above
	--
	ELSE
		a.response := format('ERROR: unknown verb «%s»', a.verb);
	END CASE;
	--
	-- Passage of time
	--
	UPDATE players
	SET user_time = user_time + a.duration
	WHERE user_name = current_user;
END;
$BODY$;

CREATE FUNCTION main_loop
( sentence IN text
, response OUT text
, stop OUT boolean
) LANGUAGE plpgsql
AS $BODY$
DECLARE
	next_action action;
BEGIN
	next_action := parse(sentence);
	CALL effect(next_action);
	stop := next_action.verb = 'QUIT';
	response := pgif_format(next_action.response);
	RETURN;
END;
$BODY$;
