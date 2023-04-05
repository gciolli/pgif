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
, ('OPEN')
, ('TAKE')
, ('WAIT')
, ('CLOSE')
) INSERT INTO verbs(id, has_effect)
SELECT id, true
FROM a;

--
-- Actions not yet implemented
--

WITH a(id) AS (VALUES
  ('SAY')
, ('USE')
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

--
-- Paths connect locations across directions.
--
-- A path can optionally have a barrier. Barriers can be opened and
-- closed, and have an optional auto_close attribute, to reflect the
-- way most doors work nowadays. For now we do not represent auto_open
-- doors as they would add little in their generic form. The only way
-- an auto open door can make sense is to depend on some specific
-- condition, such as the presence of a given object or character.
--

CREATE TABLE paths
( id text PRIMARY KEY
, src     text NOT NULL REFERENCES locations(id)
, src_dir text NOT NULL REFERENCES directions(id)
, tgt     text NOT NULL REFERENCES locations(id)
, tgt_dir text          REFERENCES directions(id)
, path_name text
, path_duration interval DEFAULT '5 minutes'
, UNIQUE (src, src_dir, tgt, tgt_dir)
);

COMMENT ON COLUMN paths.tgt_dir IS
'If tgt_dir is set, then the path is considered two-way, meaning that
it results in two one-way paths.';

CREATE TABLE barriers
( id text PRIMARY KEY REFERENCES paths(id)
, barrier_name text NOT NULL
, is_open boolean DEFAULT false
, auto_close boolean DEFAULT false
, opening_time interval DEFAULT '5 minutes'
);

CREATE VIEW characters_paths_barriers AS
WITH one_way_paths AS (
  SELECT id
  , id AS path_id
  , path_name
  , path_duration
  , src
  , src_dir
  , tgt
  FROM paths
UNION ALL
  SELECT id
  , id || '''' AS path_id
  , path_name
  , path_duration
  , tgt AS src
  , tgt_dir AS src_dir
  , src AS tgt
  FROM paths
  WHERE tgt_dir IS NOT NULL
)
SELECT c.id AS character_id
, p.path_id
, p.path_name
, p.path_duration
, p.id AS barrier_id
, b.barrier_name
, b.is_open AS barrier_is_open
, b.auto_close AS barrier_auto_close
, b.opening_time AS barrier_opening_time
, d.format AS direction_format
, d.description AS direction_description
, p.src_dir
, p.tgt
FROM characters c
JOIN one_way_paths p ON p.src = c.current_location
JOIN directions d ON d.id = p.src_dir
LEFT JOIN barriers b ON b.id = p.id;

CREATE VIEW characters_locations AS
SELECT c.id AS character_id
, l.description AS location_description
, l.name AS location_name
FROM characters c
JOIN locations l ON l.id = c.current_location;

CREATE VIEW characters_objects AS
SELECT c.id AS character_id
, o.id AS object_id
, o.article AS object_article
, o.description AS object_description
FROM characters c
JOIN objects o ON o.current_location = c.current_location
WHERE o.id != c.id;

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
	SELECT format('You are in %s.'
		, coalesce(location_description, location_name))
	INTO STRICT x
	FROM characters_locations
	WHERE character_id = current_user;
	-- (2) named exits
	SELECT string_agg
	( format
	  ( 'There is %s%s %s%s'
	  , path_name
	  , COALESCE(' with ' || barrier_name, '')
	  , format(direction_format, direction_description)
	  , CASE WHEN barrier_name IS NULL THEN '.' ELSE
	    format
	    ( E'; %s is %s.', barrier_name
	    , CASE WHEN barrier_is_open THEN 'open' ELSE 'closed'
	      END )
	    END
	  ), E'\n')
	INTO y
	FROM characters_paths_barriers
	WHERE character_id = current_user
	AND path_name IS NOT NULL;
	-- (3) anonymous exits
	SELECT string_agg(direction_description, ', ')
	INTO z
	FROM characters_paths_barriers
	WHERE character_id = current_user
	AND path_name IS NULL;
	-- (4) objects in sight
	SELECT array_agg(format('%s %s'
		, object_article, object_description))
	INTO w
	FROM characters_objects
	WHERE character_id = current_user;
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
	v_dt interval;
	v_is_open bool;
	v_direction text;
	v_target_location text;
BEGIN
	SELECT description
	INTO v_direction
	FROM directions
	WHERE upper(a.words[1]) = upper(id);
	SELECT tgt, path_duration, barrier_is_open
	INTO v_target_location, v_dt, v_is_open
	FROM characters_paths_barriers
	WHERE character_id = current_user
	AND upper(src_dir) = upper(a.words[1]);
	IF a.words = '{}' THEN
		a.response := 'GO requires a direction.';
	ELSIF FOUND AND v_is_open THEN
		UPDATE characters
		SET current_location = v_target_location
		, own_time = own_time + v_dt
		WHERE id = current_user;
		a.response := format(E'Going %s.', v_direction);
		a.look_after := true;
	ELSE
		a.response := format(E'Cannot go %s.'
			, coalesce
			( v_direction
			, format('«%s»', lower(a.words[1]))));
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

CREATE FUNCTION do_open(a INOUT actions)
LANGUAGE plpgsql
AS $BODY$
DECLARE
	v_dt interval;
	v_ids text;
	v_regexp text := array_to_string(a.words, ' ');
	v_match_count bigint;
	v_barrier_name text;
BEGIN
	SELECT string_agg(barrier_id, ' '), count(*)
	INTO v_ids, v_match_count
	FROM characters_paths_barriers v
	WHERE v.character_id = current_user
	AND v.barrier_name ~* v_regexp
	AND NOT v.barrier_is_open;
	CASE
	WHEN v_match_count = 0 THEN
		a.response := format('ERROR: cannot match «%s»', v_regexp);
	WHEN v_match_count > 1 THEN
		a.response := format
		( 'ERROR: ambiguous term «%s» could be any of: %s'
		, v_regexp, v_ids);
	ELSE
		UPDATE barriers b
		SET is_open = true
		WHERE b.id = v_ids
		RETURNING opening_time, barrier_name
		INTO STRICT v_dt, v_barrier_name;
		IF FOUND THEN
			UPDATE characters
			SET own_time = own_time + v_dt
			WHERE id = current_user;
			a.response := format(E'You open %s.'
				, v_barrier_name);
		ELSE
			a.response := format(E'You could not open «%s».'
				, v_regexp);
		END IF;
	END CASE;
END;
$BODY$;

CREATE FUNCTION do_close(a INOUT actions)
LANGUAGE plpgsql
AS $BODY$
DECLARE
	v_dt interval;
	v_ids text;
	v_regexp text := array_to_string(a.words, ' ');
	v_match_count bigint;
	v_barrier_name text;
BEGIN
	SELECT string_agg(barrier_id, ' '), count(*)
	INTO v_ids, v_match_count
	FROM characters_paths_barriers v
	WHERE v.character_id = current_user
	AND v.barrier_name ~* v_regexp
	AND v.barrier_is_open;
	CASE
	WHEN v_match_count = 0 THEN
		a.response := format('ERROR: cannot match «%s»', v_regexp);
	WHEN v_match_count > 1 THEN
		a.response := format
		( 'ERROR: ambiguous term «%s» could be any of: %s'
		, v_regexp, v_ids);
	ELSE
		UPDATE barriers b
		SET is_open = false
		WHERE b.id = v_ids
		RETURNING barrier_name
		INTO STRICT v_barrier_name;
		IF FOUND THEN
			UPDATE characters
			SET own_time = own_time + '1 minutes'
			WHERE id = current_user;
			a.response := format(E'You close %s.'
				, v_barrier_name);
		ELSE
			a.response := format(E'You could not close «%s».'
				, v_regexp);
		END IF;
	END CASE;
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
