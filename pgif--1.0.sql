-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgif" to load this file. \quit

--
-- IF schema
--

CREATE TABLE actions
( id SERIAL PRIMARY KEY
, verb text
, words text[]
, matches text
, sentence text
, response text
, look_after boolean
);

CREATE VIEW current_action AS
SELECT *
FROM actions
ORDER BY id DESC LIMIT 1;

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

CREATE TABLE verbs
( id text PRIMARY KEY
, has_effect boolean
, default_duration interval
);

COMMENT ON COLUMN verbs.has_effect IS 
'NULL denotes verbs that are not implemented yet';

--
-- Actions without effects
--

WITH a(id, default_duration) AS (VALUES
  ('HELP', '0 minutes')
, ('LOOK', '3 minutes')
, ('QUIT', '0 minutes')
, ('INVENTORY', '1 minute')
) INSERT INTO verbs(id, has_effect, default_duration)
SELECT id, false, default_duration :: interval
FROM a;

--
-- Actions with effects
--

WITH a(id) AS (VALUES
  ('GO')
, ('DROP')
, ('TAKE')
, ('WAIT')
) INSERT INTO verbs(id, has_effect)
SELECT id, true
FROM a;

--
-- Actions not yet implemented
--

WITH a(id) AS (VALUES
  ('SAY')
, ('USE')
, ('OPEN')
, ('CLOSE')
, ('EXAMINE')
) INSERT INTO verbs(id)
SELECT id
FROM a;

--
-- Objects have a location, an article and a name. They can optionally
-- have a description, and be mobile.
--
-- A container is an object that has the extra ability to host other
-- objects. It can optionally be opaque, meaning that it does not
-- reveal its contents until it is examined. Also, you need to examine
-- an object to determine whether it is a container, unless it is not
-- opaque, in which case you can see its contents.
--
-- A character is a container which is "animated", i.e. with the extra
-- ability to move spontaneously. Therefore it has its own time. While
-- it is possible for a mobile container to be moved from one location
-- to another, that fact alone does not make it animated.
--
-- A location is a container with the extra ability to host a
-- character.
--
-- Note that there can be containers that are neither characters nor
-- locations, and objects that are not containers.
--

CREATE TABLE objects
( id text PRIMARY KEY
, name text
, article text
, current_location text
, description text
, is_mobile bool DEFAULT true
);

CREATE TABLE containers
( is_opaque bool DEFAULT false
) INHERITS (objects);

CREATE TABLE locations
( UNIQUE (id)
) INHERITS (containers);

ALTER TABLE objects
ADD FOREIGN KEY (current_location) REFERENCES locations(id);

CREATE TABLE characters
( own_time timestamp(0)
) INHERITS (containers);

CREATE TABLE paths
( id text PRIMARY KEY
, src     text NOT NULL REFERENCES locations(id)
, src_dir text NOT NULL REFERENCES directions(id)
, tgt     text NOT NULL REFERENCES locations(id)
, tgt_dir text NOT NULL REFERENCES directions(id)
, path_name text
, path_duration interval
, UNIQUE (src, src_dir, tgt, tgt_dir)
);

CREATE TABLE barriers
( id text PRIMARY KEY REFERENCES paths(id)
, barrier_name text NOT NULL
, auto_close boolean DEFAULT false
, opening_time interval
);

--
-- Utility functions
--

CREATE FUNCTION pgif_time()
RETURNS text
LANGUAGE SQL
AS $BODY$
WITH a(t) AS (
  SELECT format('%s %s %s %s'
  , trim(to_char(own_time, 'Day'))
  , regexp_replace(to_char(own_time, 'DD'), '^0', '')
  , trim(to_char(own_time, 'Month'))
  , to_char(own_time, 'YYYY, HH12:MI am'))
  FROM characters
  WHERE id = current_user
)
SELECT format('--[%s]%s', t, repeat('-', 66 - length(t)))
FROM a
$BODY$;

CREATE FUNCTION pgif_format(text)
RETURNS text
LANGUAGE SQL
AS $BODY$
SELECT format(E'\n%s\n\n> ', $1)
$BODY$;

CREATE FUNCTION format_list(text[], text)
RETURNS text
LANGUAGE SQL
AS $BODY$
SELECT
CASE
WHEN $1 IS NULL THEN $2
WHEN array_length($1,1) = 1 THEN $1[1]
ELSE format
( '%s and %s'
, array_to_string($1[1:array_length($1,1)-1], ', ')
, $1[array_length($1,1)]
)
END
$BODY$;

--
-- IF actions
--

CREATE FUNCTION do_help()
RETURNS text
LANGUAGE SQL
AS $BODY$
WITH a (id, n) AS (
SELECT CASE
WHEN has_effect IS NULL THEN format('%s (*)', id)
ELSE id
END, row_number() OVER (ORDER BY id)
FROM verbs
) SELECT format($$Available verbs:

%s

(*) = not implemented yet$$
, string_agg
( format('%-20s   %-20s   %-20s', a.id, a1.id, a2.id), E'\n'
  ORDER BY a.n ))
FROM a
JOIN a AS a1 ON a.n + 5 = a1.n
LEFT JOIN a AS a2 ON a.n + 10 = a2.n
WHERE a.n <= 5
$BODY$;

CREATE FUNCTION do_quit()
RETURNS text
LANGUAGE SQL
AS $BODY$
SELECT NULL;
$BODY$;

CREATE FUNCTION do_look()
RETURNS text
LANGUAGE plpgsql
AS $BODY$
DECLARE
	x text;
	y text;
	z text;
	w text[];
BEGIN
	-- (1) description
	SELECT format('You are in %s.', coalesce(l.description, l.name))
	INTO STRICT x
	FROM locations l
	, characters u
	WHERE l.id = u.current_location
	AND u.id = current_user;
	-- (2) named exits
	SELECT string_agg
	( format
	  ( 'There is %s%s %s.'
	  , p.path_name
	  , COALESCE(' with ' || b.barrier_name, '')
	  , format(d.format, d.description)
	  ), E'\n')
	INTO y
	FROM characters u
	JOIN paths p ON p.src = u.current_location
	JOIN directions d ON p.src_dir = d.id
	LEFT JOIN barriers b ON p.id = b.id
	WHERE u.id = current_user
	AND p.path_name IS NOT NULL;
	-- (3) anonymous exits
	SELECT string_agg(d.description, ', ')
	INTO z
	FROM characters u
	, paths p
	, directions d
	WHERE u.id = current_user
	AND p.src = u.current_location
	AND p.src_dir = d.id
	AND p.path_name IS NULL;
	-- (4) objects in sight
	SELECT array_agg(format('%s %s', o.article, o.description))
	INTO w
	FROM characters u
	, objects o
	WHERE u.id = current_user
	AND o.id != current_user
	AND o.current_location = u.current_location;
	--
	RETURN format
	( E'%s\n%s\n%s\n%s\n%s'
	, pgif_time()
	, x
	, y
	, CASE WHEN z IS NULL
	  THEN 'No other exits available.'
	  ELSE format('Other exits: %s', z)
	  END
	, CASE WHEN w IS NULL
	  THEN ''
	  ELSE format('You can see %s.', format_list(w, 'no objects'))
	  END
	);
END;
$BODY$;

CREATE FUNCTION do_inventory()
RETURNS text
LANGUAGE plpgsql
AS $BODY$
DECLARE
	w text[];
BEGIN
	SELECT array_agg(format('%s %s', o.article, o.description))
	INTO w
	FROM objects o
	WHERE o.current_location = current_user;
	--
	RETURN format
	( E'%s\nYou are carrying %s.'
	, pgif_time()
	, format_list(w, 'no objects')
	);
END;
$BODY$;

CREATE FUNCTION do_go(a INOUT actions)
LANGUAGE plpgsql
AS $BODY$
DECLARE
	x text;
	y text;
	z interval;
BEGIN
	SELECT description
	INTO y
	FROM directions
	WHERE upper(a.words[1]) = upper(id);
	SELECT p.tgt, p.path_duration
	INTO x, z
	FROM characters u
	JOIN paths p
	  ON p.src = u.current_location
	 AND upper(p.src_dir) = upper(a.words[1])
	WHERE u.id = current_user;
	IF a.words = '{}' THEN
		a.response := 'GO requires a direction.';
	ELSIF FOUND THEN
		UPDATE characters
		SET current_location = x
		, own_time = own_time + z
		WHERE id = current_user;
		a.response := format(E'Going %s.', y);
		a.look_after := true;
	ELSE
		a.response := format(E'Cannot go %s.', lower(a.words[1]));
	END IF;
END;
$BODY$;

CREATE FUNCTION do_take(a INOUT actions)
LANGUAGE plpgsql
AS $BODY$
DECLARE
	x text;
BEGIN
	UPDATE objects o
	SET current_location = current_user
	FROM characters u
	WHERE o.current_location = u.current_location
	AND upper(o.name) = upper(a.words[1])
	RETURNING format('%s %s', o.article, o.description) INTO x;
	IF FOUND THEN
		UPDATE characters
		SET own_time = own_time + '2 minutes'
		WHERE id = current_user;
		a.response := format(E'You take %s.', x);
		a.look_after := true;
	ELSE
		a.response := format(E'You cannot see any %s.', lower(a.words[1]));
	END IF;
END;
$BODY$;

CREATE FUNCTION do_drop(a INOUT actions)
LANGUAGE plpgsql
AS $BODY$
DECLARE
	x text;
BEGIN
	UPDATE objects o
	SET current_location = u.current_location
	FROM characters u
	WHERE o.current_location = current_user
	AND upper(o.name) = upper(a.words[1])
	RETURNING format('%s %s', o.article, o.description) INTO x;
	IF FOUND THEN
		UPDATE characters
		SET own_time = own_time + '2 minutes'
		WHERE id = current_user;
		a.response := format(E'You drop %s.', x);
		a.look_after := true;
	ELSE
		a.response := format(E'You do not have any %s.', lower(a.words[1]));
	END IF;
END;
$BODY$;

CREATE FUNCTION do_wait(a INOUT actions)
LANGUAGE plpgsql
AS $BODY$
DECLARE
	x interval;
BEGIN
	x := COALESCE(NULLIF(array_to_string(a.words, ' '), ''), '5 minutes');
	UPDATE characters
	SET own_time = own_time + x
	WHERE id = current_user;
	a.response := CASE WHEN x > '0 minutes' THEN 'You wait.' ELSE '' END;
	a.look_after := true;
END;
$BODY$;

CREATE FUNCTION do_missing(a INOUT actions)
LANGUAGE plpgsql
AS $BODY$
BEGIN
	a.response := format('Apologies: %s not yet implemented.', a.matches);
END;
$BODY$;

--
-- IF engine
--

CREATE FUNCTION parse(text)
RETURNS actions
LANGUAGE plpgsql
AS $BODY$
DECLARE
	a actions;
	words text[];
BEGIN
	-- (1) sanitise input
	a.sentence := regexp_replace($1, '"', ' " ', 'g');
	a.sentence := regexp_replace(a.sentence, '	', ' ', 'g');
	a.sentence := regexp_replace(a.sentence, '  +', ' ', 'g');

	-- (2) split in words
	words := string_to_array(upper(trim(a.sentence)), ' ');
	IF words = '{}' THEN
		a.verb := 'HELP';
	ELSIF words[1:1] <@ '{N,S,E,W,NE,SE,SW,NW,U,D}' THEN
		a.verb := 'GO';
		a.words := words[1:1];
	ELSE
		a.verb := words[1];
		a.words := words[2:];
	END IF;

	RETURN a;
END;
$BODY$;

CREATE PROCEDURE dispatch(a INOUT actions)
LANGUAGE plpgsql
AS $BODY$
DECLARE
	v_id text;
	v_he boolean;
	v_regexp text := format('^%s', a.verb);
	v_match_count bigint;
	v_duration interval;
	dispatch_sql text;
BEGIN
	SELECT string_agg(id, ' '), count(*)
	INTO a.matches, v_match_count
	FROM verbs
	WHERE id ~* v_regexp;
	SELECT id, has_effect, default_duration
	INTO v_id, v_he, v_duration
	FROM verbs
	WHERE id ~* v_regexp;
	CASE
	WHEN v_match_count = 0 THEN
		a.response := format('ERROR: unknown verb «%s»', a.verb);
	WHEN v_match_count > 1 THEN
		a.response := format
		( 'ERROR: ambiguous verb «%s» could be: %s'
		, a.verb, a.matches);
	WHEN v_he IS NULL THEN
		SELECT * INTO STRICT a FROM do_missing(a);
	WHEN v_he THEN
		a.look_after := false;
		dispatch_sql := format('SELECT * FROM do_%s($1)', lower(v_id));
		EXECUTE dispatch_sql INTO STRICT a USING a;
		IF a.look_after THEN
			a.response := format(E'%s\n\n%s', a.response, do_look());
		END IF;
	WHEN NOT v_he THEN
		-- Passage of time
		UPDATE characters
		SET own_time = own_time + coalesce(v_duration, '0 minutes')
		WHERE id = current_user;
		-- Display
		dispatch_sql := format('SELECT * FROM do_%s()', lower(v_id));
		EXECUTE dispatch_sql INTO STRICT a.response;
	END CASE;
END;
$BODY$;

CREATE FUNCTION main_loop
( sentence IN text
, response OUT text
, stop OUT boolean
) LANGUAGE plpgsql
AS $BODY$
DECLARE
	next_action actions;
BEGIN
	next_action := parse(sentence);
	CALL dispatch(next_action);
	INSERT INTO actions
	( verb
	, words
	, matches
	, sentence
	, response
	, look_after
	) SELECT
	  (next_action).verb
	, (next_action).words
	, (next_action).matches
	, (next_action).sentence
	, (next_action).response
	, (next_action).look_after;
	stop := next_action.matches = 'QUIT';
	response := pgif_format(next_action.response);
	RETURN;
END;
$BODY$;
