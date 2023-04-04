# Overview

`pgif` is a PostgreSQL extension which provides an engine for
Interactive Fiction adventures.

Each adventure can be implemented as a separate Postgres extension
with an explicit dependence on `pgif`.

# Quickstart

    sudo make install
    psql -c "create extension testpgif cascade"
    psql -f start.sql
