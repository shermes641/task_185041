"""Connection settings and helpers shared by conftest.py and the tests."""
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
HOST, PORT, USER, PASSWORD = "127.0.0.1", 5434, "postgres", "dawn"
SCRATCH = "dawn_scratch"


def psql(dbname: str, *args: str) -> None:
    env = {**os.environ, "PGPASSWORD": PASSWORD}
    subprocess.run(["psql", "-q", "-v", "ON_ERROR_STOP=1", "-h", HOST, "-p", str(PORT), "-U", USER,
                    "-d", dbname, *args], check=True, env=env, capture_output=True, text=True)


def seed_files() -> list[pathlib.Path]:
    return sorted((ROOT / "seeds").glob("[0-9][0-9][0-9]_*.sql"))


def apply_seeds() -> None:
    for f in seed_files():
        psql(SCRATCH, "-f", str(f))
