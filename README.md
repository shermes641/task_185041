# Bergrivier 2026/27 charges (practice workspace)

Record this task in Cursor: open this folder as the workspace.

Cut-down copy: three tariffs (5, 18, 19) of a tariff database, the public Bergrivier 2026/27 documents, and the
current seed/requirement rows for those tariffs.

Load the DB by hand (pytest does this itself): docker compose up -d, then
psql "postgresql://postgres:dawn@127.0.0.1:5434/postgres" -f db/tariff_dev_v2_bergrivier_subset.sql

Rates are in cents. docs/ holds the source documents and a glossary.

## Tests
Goal: the charges below are in the DB (schema tariff_dev_v2) in cents, for the RfD dates, citing their source.

    docker compose up -d
    pytest tests/test_bergrivier_2026_27.py

Write your seed as seeds/NNN_*.sql; conftest.py rebuilds a scratch database, loads db/*.sql, then applies your seeds.
