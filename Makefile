EXTENSION = pgif testpgif
DATA = pgif--1.0.sql testpgif--1.0.sql

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
