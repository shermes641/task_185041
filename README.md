# Bergrivier 2026/27 charges (practice workspace)

Record this task in Cursor: open this folder as the workspace.

Cut-down copy: three tariffs (5, 18, 19) of a tariff database, the public Bergrivier 2026/27 documents, and the
current seed/requirement rows for those tariffs. Rates are stored in cents. `docs/` holds the RfD, the Annex A PDF
and a short glossary.

## Task
Add the missing basic, reactive-energy and per-Amp demand charges for tariffs 5, 18 and 19 as a seed file
`seeds/NNN_*.sql` (schema `tariff_dev_v2`). Every rate must match the RfD, run 1 July 2026 to 30 June 2027,
and cite its source. The tests start with 7 failing and 6 passing; the goal is all green.

## Install the prerequisites
You need four things: git, uv (Python + dependencies), Docker (runs Postgres) and the `psql` client.

### macOS
1. Install [Homebrew](https://brew.sh) if you don't have it.
2. Install the tools:
   ```bash
   brew install git uv libpq
   brew link --force libpq          # puts psql on your PATH
   brew install --cask docker       # Docker Desktop
   ```
3. Open **Docker Desktop** once from Applications and wait until it says "Engine running".

### Windows
1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) (enable the WSL 2 backend when asked) and start it.
2. In PowerShell:
   ```powershell
   winget install Git.Git
   winget install astral-sh.uv
   winget install PostgreSQL.PostgreSQL.17   # includes psql; add its bin folder to PATH
   ```
   Or run everything inside WSL 2 and follow the Linux steps.

### Linux (Debian/Ubuntu)
```bash
sudo apt update && sudo apt install -y git postgresql-client curl
curl -LsSf https://astral.sh/uv/install.sh | sh     # uv; restart the shell afterwards
curl -fsSL https://get.docker.com | sh              # Docker Engine
sudo usermod -aG docker $USER                       # log out and back in
```

### Check everything is installed
```bash
git --version && uv --version && docker --version && docker info >/dev/null && psql --version
```
`docker info` fails if Docker isn't running; start Docker Desktop (or `sudo systemctl start docker`) and retry.
uv installs the right Python (>= 3.11) by itself; you don't need to install Python.

## Quick start

```bash
git clone https://github.com/shermes641/task_185041.git && cd task_185041
uv sync                 # creates .venv (Python >= 3.11) with pytest and psycopg2
docker compose up -d    # Postgres on 127.0.0.1:5434 (password "dawn"); wait a few seconds
uv run pytest           # first run: 7 failed, 6 passed
```

`tests/conftest.py` drops and recreates a scratch database `dawn_scratch` each run, loads
`db/tariff_dev_v2_bergrivier_subset.sql`, then applies your `seeds/[0-9][0-9][0-9]_*.sql` files in order.
Run a single test with `uv run pytest -k reactive`. Stop the database with `docker compose down`.

To explore by hand:
`psql "postgresql://postgres:dawn@127.0.0.1:5434/dawn_scratch"` (after a test run), or load the subset into any
empty database with `psql ... -f db/tariff_dev_v2_bergrivier_subset.sql`.
