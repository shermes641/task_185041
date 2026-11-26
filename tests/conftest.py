"""Loads the subset into a scratch database, applies seeds/NNN_*.sql, and exposes a query helper.

Needs: the Docker DB from docker-compose.yml (port 5434), psql on PATH, psycopg2, pytest.
The scratch database is dropped and recreated every session; nothing else is touched.
"""
import psycopg2
import pytest

import dbtools


@pytest.fixture(scope="session")
def db():
    admin = psycopg2.connect(host=dbtools.HOST, port=dbtools.PORT, user=dbtools.USER,
                             password=dbtools.PASSWORD, dbname="postgres")
    admin.autocommit = True
    with admin.cursor() as cur:
        cur.execute(f"DROP DATABASE IF EXISTS {dbtools.SCRATCH}")
        cur.execute(f"CREATE DATABASE {dbtools.SCRATCH}")
    admin.close()
    dbtools.psql(dbtools.SCRATCH, "-f", str(dbtools.ROOT / "db" / "tariff_dev_v2_bergrivier_subset.sql"))
    dbtools.apply_seeds()
    conn = psycopg2.connect(host=dbtools.HOST, port=dbtools.PORT, user=dbtools.USER,
                            password=dbtools.PASSWORD, dbname=dbtools.SCRATCH)
    conn.autocommit = True
    yield conn
    conn.close()


@pytest.fixture()
def q(db):
    """q(sql, params) -> list of tuples."""
    def run(sql, params=None):
        with db.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall() if cur.description else []
    return run
