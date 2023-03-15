SELECT * FROM main_loop(:'sentence')\gset

\if :stop
\quit
\endif

\prompt :response sentence

\ir repl.sql
