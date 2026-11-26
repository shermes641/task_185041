Put your new seed file here as seeds/NNN_name.sql (for example 001_bergrivier_2026_27.sql).
It is applied by tests/conftest.py to schema tariff_dev_v2, after the subset loads. Keep it idempotent.
reference/seed_before_excerpt.sql shows the style of the existing seeds (it targets another schema name).
