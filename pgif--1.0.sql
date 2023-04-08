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

SELECT pg_catalog.pg_extension_config_dump('actions', '');
SELECT pg_catalog.pg_extension_config_dump('actions_id_seq', '');

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
-- The hierarchy of Objects is implemented with two distinct tables,
-- to separate metadata from state, in a way that is compatible with
-- how PostgreSQL extensions work.
--
-- Actual data types such as Characters, Containers, Locations and
-- Objects are implemented as views on object_{metadata,state},
-- exposing only the columns that make sense. Triggers implement
-- appropriate DML.
--
-- Note that there can be containers that are neither characters nor
-- locations, and objects that are not containers.
--

CREATE TABLE object_metadata
( id text PRIMARY KEY
, name text
, article text
, location text REFERENCES object_metadata(id)
, own_time timestamp(0)
, is_mobile bool DEFAULT true
, is_opaque bool
, description text
);

CREATE TABLE object_state
( id text PRIMARY KEY REFERENCES object_metadata(id)
, location text REFERENCES object_metadata(id)
, own_time timestamp(0)
);

SELECT pg_catalog.pg_extension_config_dump('object_state', '');

--
-- Objects have a location, an article and a name. They can optionally
-- be mobile.
--

CREATE VIEW objects AS
SELECT id
, name
, article
, COALESCE(s.location, m.location) AS location
, is_mobile
FROM object_metadata m
JOIN object_state s USING (id);

CREATE FUNCTION tf_objects()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $BODY$
BEGIN
  CASE TG_OP
  WHEN 'INSERT' THEN
    INSERT INTO object_metadata
    ( id
    , name
    , article
    , location
    , is_mobile
    ) VALUES
    ( NEW.id
    , NEW.name
    , NEW.article
    , NEW.location
    , COALESCE(NEW.is_mobile, true)
    );
  WHEN 'UPDATE' THEN
    -- Ensure we are not updating static columns
    ASSERT NEW.id               = OLD.id;
    ASSERT NEW.name             = OLD.name;
    ASSERT NEW.article          = OLD.article
        OR NEW.article IS NULL;
    ASSERT NEW.is_mobile        = OLD.is_mobile
        OR NEW.is_mobile IS NULL;
    -- Apply the update
    UPDATE object_state
    SET location = NEW.location
    WHERE id = NEW.id;
  END CASE;
  RETURN NEW;
END;
$BODY$;

CREATE TRIGGER tg_objects
  INSTEAD OF INSERT OR UPDATE ON objects
  FOR EACH ROW
  EXECUTE PROCEDURE tf_objects();

--
-- A Container is an object that has the extra ability to host other
-- objects.  The container can optionally be opaque, meaning that it
-- does not reveal its contents until it is examined. Also, you need
-- to examine an object to determine whether it is a container, unless
-- it is not opaque, in which case you can see its contents.
--

COMMENT ON COLUMN object_metadata.is_opaque IS
'An object is a container if is_opaque is not null';

CREATE VIEW containers AS
SELECT id
, name
, article
, COALESCE(s.location, m.location) AS location
, is_mobile
, is_opaque
FROM object_metadata m
JOIN object_state s USING (id)
WHERE is_opaque IS NOT NULL;

CREATE FUNCTION tf_containers()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $BODY$
BEGIN
  CASE TG_OP
  WHEN 'INSERT' THEN
    INSERT INTO object_metadata
    ( id
    , name
    , article
    , location
    , is_mobile
    , is_opaque
    ) VALUES
    ( NEW.id
    , NEW.name
    , NEW.article
    , NEW.location
    , COALESCE(NEW.is_mobile, true)
    , NEW.is_opaque
    );
  WHEN 'UPDATE' THEN
    -- Ensure we are not updating static columns
    ASSERT NEW.id               = OLD.id;
    ASSERT NEW.name             = OLD.name;
    ASSERT NEW.article          = OLD.article
        OR NEW.article IS NULL;
    ASSERT NEW.is_mobile        = OLD.is_mobile
        OR NEW.is_mobile IS NULL;
    ASSERT NEW.is_opaque        = OLD.is_opaque;
    -- Apply the update
    UPDATE object_state
    SET location = NEW.location
    WHERE id = NEW.id;
  END CASE;
  RETURN NEW;
END;
$BODY$;

CREATE TRIGGER tg_containers
  INSTEAD OF INSERT OR UPDATE ON containers
  FOR EACH ROW
  EXECUTE PROCEDURE tf_containers();

--
-- A Location is a container with the extra ability to host a
-- character; therefore it must have a description which is displayed
-- to visiting characters.
--

COMMENT ON COLUMN object_metadata.description IS
'A container is a location if description is not null';

CREATE VIEW locations AS
SELECT id
, name
, article
, location
, is_mobile
, is_opaque
, description
FROM object_metadata
WHERE is_opaque IS NOT NULL
  AND description IS NOT NULL;

CREATE FUNCTION tf_locations()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $BODY$
BEGIN
  CASE TG_OP
  WHEN 'INSERT' THEN
    ASSERT NEW.description IS NOT NULL
    , 'locations require a description';
    INSERT INTO object_metadata
    ( id
    , name
    , article
    , location
    , is_mobile
    , is_opaque
    , description
    ) VALUES
    ( NEW.id
    , NEW.name
    , NEW.article
    , NEW.location
    , COALESCE(NEW.is_mobile, true)
    , COALESCE(NEW.is_opaque, true)
    , NEW.description
    );
  END CASE;
  RETURN NEW;
END;
$BODY$;

CREATE TRIGGER tg_locations
  INSTEAD OF INSERT ON locations
  FOR EACH ROW
  EXECUTE PROCEDURE tf_locations();

--
-- A Character is a container which is "animated", i.e. with the extra
-- ability to move spontaneously. Therefore it has its own time. While
-- it is possible for a mobile container to be moved from one location
-- to another, that fact alone does not make it animated.
--

COMMENT ON COLUMN object_metadata.own_time IS
'A container is a character if own_time is not null';

CREATE VIEW characters AS
SELECT id
, name
, article
, COALESCE(s.location, m.location) AS location
, COALESCE(s.own_time, m.own_time) AS own_time
, is_mobile
, is_opaque
FROM object_metadata m
JOIN object_state s USING (id)
WHERE is_opaque IS NOT NULL
  AND m.own_time IS NOT NULL;

CREATE FUNCTION tf_characters()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $BODY$
BEGIN
  CASE TG_OP
  WHEN 'INSERT' THEN
    INSERT INTO object_metadata
    ( id
    , name
    , article
    , location
    , own_time
    , is_mobile
    , is_opaque
    ) VALUES
    ( NEW.id
    , NEW.name
    , NEW.article
    , NEW.location
    , NEW.own_time
    , COALESCE(NEW.is_mobile, true)
    , NEW.is_opaque
    );
  WHEN 'UPDATE' THEN
    -- Ensure we are not updating static columns
    ASSERT NEW.id               = OLD.id;
    ASSERT NEW.name             = OLD.name;
    ASSERT NEW.article          = OLD.article
        OR NEW.article IS NULL;
    ASSERT NEW.is_mobile        = OLD.is_mobile
        OR NEW.is_mobile IS NULL;
    ASSERT NEW.is_opaque        = OLD.is_opaque;
    -- Apply the update
    UPDATE object_state
    SET location = NEW.location
    ,   own_time = NEW.own_time
    WHERE id = NEW.id;
  END CASE;
  RETURN NEW;
END;
$BODY$;

CREATE TRIGGER tg_characters
  INSTEAD OF INSERT OR UPDATE ON characters
  FOR EACH ROW
  EXECUTE PROCEDURE tf_characters();

--
-- Paths connect locations across directions.
--

CREATE TABLE paths
( id text PRIMARY KEY
, src     text NOT NULL REFERENCES object_metadata(id)
, tgt     text NOT NULL REFERENCES object_metadata(id)
, src_dir text NOT NULL REFERENCES directions(id)
, tgt_dir text          REFERENCES directions(id)
, path_name text
, path_duration interval DEFAULT '5 minutes'
, UNIQUE (src, src_dir, tgt, tgt_dir)
);

COMMENT ON COLUMN paths.tgt_dir IS
'If tgt_dir is set, then the path is considered two-way, meaning that
it results in two one-way paths.';

--
-- A path can optionally have a barrier. Barriers can be opened and
-- closed, and have an optional auto_close attribute, to reflect the
-- way most doors work nowadays. For now we do not represent auto_open
-- doors as they would add little in their generic form. The only way
-- an auto open door can make sense is to depend on some specific
-- condition, such as the presence of a given object or character.
--

CREATE TABLE barrier_metadata
( id text PRIMARY KEY REFERENCES paths(id)
, is_closed boolean DEFAULT false
, auto_close boolean DEFAULT false
, barrier_name text NOT NULL
, opening_time interval DEFAULT '5 minutes'
);

CREATE TABLE barrier_state
( id text PRIMARY KEY REFERENCES barrier_metadata(id)
, is_closed boolean DEFAULT false
);

SELECT pg_catalog.pg_extension_config_dump('barrier_state', '');

CREATE VIEW barriers AS
SELECT id
, COALESCE(s.is_closed, m.is_closed) AS is_closed
, auto_close
, barrier_name
, opening_time
FROM barrier_metadata m
JOIN barrier_state s USING (id);

CREATE FUNCTION tf_barriers()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $BODY$
BEGIN
  CASE TG_OP
  WHEN 'INSERT' THEN
    INSERT INTO barrier_metadata
    ( id
    , is_closed
    , auto_close
    , barrier_name
    , opening_time
    ) VALUES
    ( NEW.id
    , COALESCE(NEW.is_closed, false)
    , COALESCE(NEW.auto_close, false)
    , NEW.barrier_name
    , COALESCE(NEW.opening_time, '5 minutes')
    );
  WHEN 'UPDATE' THEN
    -- Ensure we are not updating static columns
    ASSERT NEW.id               = OLD.id;
    ASSERT NEW.auto_close       = OLD.auto_close;
    ASSERT NEW.barrier_name     = OLD.barrier_name;
    ASSERT NEW.opening_time     = OLD.opening_time;
    -- Apply the update
    UPDATE barrier_state
    SET is_closed = NEW.is_closed
    WHERE id = NEW.id;
  END CASE;
  RETURN NEW;
END;
$BODY$;

CREATE TRIGGER tg_barriers
  INSTEAD OF INSERT OR UPDATE ON barriers
  FOR EACH ROW
  EXECUTE PROCEDURE tf_barriers();

--
-- API views
--

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
, b.is_closed AS barrier_is_closed
, b.auto_close AS barrier_auto_close
, b.opening_time AS barrier_opening_time
, d.format AS direction_format
, d.description AS direction_description
, p.src_dir
, p.tgt
FROM characters c
JOIN one_way_paths p
  ON p.src = c.location
JOIN directions d
  ON d.id = p.src_dir
LEFT JOIN barriers b
  ON b.id = p.id;

CREATE VIEW characters_locations AS
SELECT c.id AS character_id
, l.description AS location_description
FROM characters c
JOIN locations l
  ON l.id = c.location;

CREATE VIEW characters_objects AS
SELECT c.id AS character_id
, o.id AS object_id
, o.article AS object_article
, o.name AS object_name
FROM characters c
JOIN objects o
  ON o.location = c.location
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
  WHERE id = 'you'
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
SELECT CASE
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
)
SELECT format($$Available verbs:

%s

(*) = not implemented yet$$
, string_agg
( format('%-20s	  %-20s	  %-20s', a.id, a1.id, a2.id), E'\n'
  ORDER BY a.n ))
FROM a
JOIN a AS a1
  ON a.n + 5 = a1.n
LEFT JOIN a AS a2
  ON a.n + 10 = a2.n
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
  SELECT format(E'You are in %s.', location_description)
  INTO STRICT x
  FROM characters_locations
  WHERE character_id = 'you';
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
      , CASE WHEN barrier_is_closed THEN 'closed' ELSE 'open'
        END )
      END
    ), E'\n')
  INTO y
  FROM characters_paths_barriers
  WHERE character_id = 'you'
  AND path_name IS NOT NULL;
  -- (3) anonymous exits
  SELECT string_agg(direction_description, ', ')
  INTO z
  FROM characters_paths_barriers
  WHERE character_id = 'you'
  AND path_name IS NULL;
  -- (4) objects in sight
  SELECT array_agg(format('%s %s'
    , object_article, object_name))
  INTO w
  FROM characters_objects
  WHERE character_id = 'you';
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
  x text[];
BEGIN
  SELECT array_agg(format('%s %s', o.article, o.name))
  INTO x
  FROM objects o
  WHERE o.location = 'you';
  --
  RETURN format
  ( E'%s\nYou are carrying %s.'
  , pgif_time()
  , format_list(x, 'no objects')
  );
END;
$BODY$;

CREATE FUNCTION do_go(a INOUT actions)
LANGUAGE plpgsql
AS $BODY$
DECLARE
  v_dt interval;
  v_is_closed bool;
  v_direction text;
  v_target_location text;
BEGIN
  SELECT description
  INTO v_direction
  FROM directions
  WHERE upper(a.words[1]) = upper(id);
  SELECT tgt, path_duration, barrier_is_closed
  INTO v_target_location, v_dt, v_is_closed
  FROM characters_paths_barriers
  WHERE character_id = 'you'
  AND upper(src_dir) = upper(a.words[1]);
  IF a.words = '{}' THEN
    a.response := 'GO requires a direction.';
  ELSIF FOUND AND v_is_closed THEN
    a.response := format(E'Cannot go %s.'
      , coalesce
      ( v_direction
      , format('«%s»', lower(a.words[1]))));
  ELSE
    UPDATE characters
    SET location = v_target_location
    , own_time = own_time + v_dt
    WHERE id = 'you';
    a.response := format(E'Going %s.', v_direction);
    a.look_after := true;
  END IF;
END;
$BODY$;

CREATE FUNCTION do_take(a INOUT actions)
LANGUAGE plpgsql
AS $BODY$
DECLARE
  v_matches text;
BEGIN
  SELECT match
  ( word := a.words[1]
  , candidates := array_agg(format
      ( '%s %s'
      , object_article
      , object_name
      )
    )
  , not_matching := 'thing that can be taken'
  ) INTO v_matches
  FROM characters_objects
  WHERE character_id = 'you';
  UPDATE objects o
  SET location = 'you'
  FROM characters u
  WHERE o.location = u.location
  AND format('%s %s', o.article, o.name) = v_matches;
  IF FOUND THEN
    UPDATE characters
    SET own_time = own_time + '2 minutes'
    WHERE id = 'you';
    a.response := format(E'You take %s.', v_matches);
    a.look_after := true;
  ELSE
    a.response := v_matches;
  END IF;
END;
$BODY$;

CREATE FUNCTION do_drop(a INOUT actions)
LANGUAGE plpgsql
AS $BODY$
DECLARE
  v_matches text;
BEGIN
  SELECT match
  ( word := a.words[1]
  , candidates := array_agg(format
      ( '%s %s'
      , article
      , name
      )
    )
  , not_matching := 'thing that can be dropped'
  ) INTO v_matches
  FROM objects
  WHERE location = 'you';
  UPDATE objects o
  SET location = u.location
  FROM characters u
  WHERE o.location = 'you'
  AND format('%s %s', o.article, o.name) = v_matches;
  IF FOUND THEN
    UPDATE characters
    SET own_time = own_time + '2 minutes'
    WHERE id = 'you';
    a.response := format(E'You drop %s.', v_matches);
    a.look_after := true;
  ELSE
    a.response := v_matches;
  END IF;
END;
$BODY$;

CREATE FUNCTION do_open(a INOUT actions)
LANGUAGE plpgsql
AS $BODY$
DECLARE
  v_dt interval;
  v_matches text;
BEGIN
  SELECT match
  ( word := a.words[1]
  , candidates := array_agg(barrier_name)
  , not_matching := 'thing that can be opened'
  ) INTO v_matches
  FROM characters_paths_barriers
  WHERE character_id = 'you'
  AND barrier_is_closed;
  UPDATE barriers
  SET is_closed = false
  WHERE barrier_name = v_matches
  RETURNING opening_time
  INTO v_dt;
  IF FOUND THEN
    UPDATE characters
    SET own_time = own_time + v_dt
    WHERE id = 'you';
    a.response := format(E'You open %s.', v_matches);
  ELSE
    a.response := v_matches;
  END IF;
END;
$BODY$;

CREATE FUNCTION do_close(a INOUT actions)
LANGUAGE plpgsql
AS $BODY$
DECLARE
  v_matches text;
BEGIN
  SELECT match
  ( word := a.words[1]
  , candidates := array_agg(barrier_name)
  , not_matching := 'thing that can be closed'
  ) INTO v_matches
  FROM characters_paths_barriers
  WHERE character_id = 'you'
  AND NOT barrier_is_closed;
  UPDATE barriers
  SET is_closed = true
  WHERE barrier_name = v_matches;
  IF FOUND THEN
    a.response := format(E'You close %s.', v_matches);
  ELSE
    a.response := v_matches;
  END IF;
END;
$BODY$;

CREATE FUNCTION do_wait(a INOUT actions)
LANGUAGE plpgsql
AS $BODY$
DECLARE
  dt interval;
BEGIN
  dt := COALESCE
  ( NULLIF (array_to_string(a.words, ' '), '')
    , '5 minutes');
  UPDATE characters
  SET own_time = own_time + dt
  WHERE id = 'you';
  a.response := CASE WHEN dt > '0 minutes' THEN 'You wait.' ELSE '' END;
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

CREATE FUNCTION match
( word IN text
, candidates IN text[]
, regexp IN text DEFAULT '%s'
, response OUT text
, not_matching IN text DEFAULT 'thing'
) LANGUAGE plpgsql
AS $BODY$
DECLARE
  v_matches text[];
BEGIN
  SELECT array_agg(x)
  INTO v_matches
  FROM unnest(candidates) AS f(x)
  WHERE x ~* format(regexp, word);
  CASE
  WHEN v_matches IS NULL THEN
    response := format
    ( 'ERROR: «%s» does not match any%s', word, not_matching);
  WHEN array_length(v_matches, 1) > 1 THEN
    response := format
    ( 'ERROR: ambiguous term «%s» matches: %s'
    , word, array_to_string(v_matches, ', ')
    );
  ELSE
    response := v_matches[1];
  END CASE;
END;
$BODY$;

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
  v_duration interval;
  dispatch_sql text;
BEGIN
  SELECT match
  ( word := a.verb
  , regexp := '^%s'
  , candidates := array_agg(id)
  , not_matching := ' valid verb'
  ) INTO a.matches
  FROM verbs;
  SELECT id, has_effect, default_duration
  INTO v_id, v_he, v_duration
  FROM verbs
  WHERE id = a.matches;
  CASE
  WHEN NOT FOUND THEN
    a.response := a.matches;
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
    WHERE id = 'you';
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
