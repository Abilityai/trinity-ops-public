#!/usr/bin/env python3
"""Trinity SQLite -> PostgreSQL data copy (#300 migration).

Pure stdlib sqlite3 + psycopg2 — both ship in the trinity-backend image since
Trinity #1093. No Trinity imports, no platform env needed. Designed to run as
a one-off container against a COLD SNAPSHOT of the SQLite DB (never the live
file):

    docker run --rm -i --network trinity-platform-network \
      -v ~/backups:/backup:ro \
      -e SQLITE_PATH=/backup/<snapshot>.db \
      -e PG_URL=postgresql://trinity:<pw>@postgres:5432/trinity \
      trinity-backend python3 - [--verify-only] < sqlite_to_pg_etl.py

The PostgreSQL schema must already exist, created by Trinity's own
`db.schema.init_schema_postgres()` (schema.py is the single source of truth —
this script copies DATA ONLY and never issues DDL).

Failsafe properties:
  - SQLite is opened read-only + immutable (it is a cold snapshot).
  - Refuses to load into non-empty tables — no partial merges, ever.
  - Hard-fails on schema drift (SQLite tables/columns the PG schema lacks),
    except known sqlite-only artifacts (schema_migrations, sqlite_sequence).
  - Per-column type coercion for the #1093 dialect classes (Python bool /
    numeric-string into INTEGER columns, numbers into TEXT columns).
  - Entire load is ONE transaction: any error -> nothing persisted.
  - Resets every SERIAL sequence to MAX(col) so post-migration inserts do
    not collide with copied primary keys.
  - Verifies per-table rowcounts; exit 0 only if every table matches.

Exit codes: 0 ok | 1 usage | 2 rowcount mismatch | 3 schema drift | 4 load error
"""

import os
import sys
import sqlite3

import psycopg2
import psycopg2.extras

SQLITE_PATH = os.environ.get("SQLITE_PATH")
PG_URL = os.environ.get("PG_URL")
VERIFY_ONLY = "--verify-only" in sys.argv
BATCH = 1000

# sqlite-only artifacts that intentionally have no PostgreSQL counterpart:
# migrations are an SQLite-only mechanism (#300 builds PG fresh from schema.py)
SQLITE_ONLY_OK = {"schema_migrations", "sqlite_sequence"}

INT_TYPES = {"integer", "bigint", "smallint"}
FLOAT_TYPES = {"double precision", "real", "numeric"}
TEXT_TYPES = {"text", "character varying", "character"}


class EtlError(Exception):
    pass


def fail(code, msg):
    print(f"\nETL FAILED: {msg}", file=sys.stderr)
    sys.exit(code)


def coerce(value, pg_type, ctx):
    """Coerce a SQLite value for a PostgreSQL column. SQLite is dynamically
    typed and tolerated bools/strings in INTEGER columns and numbers in TEXT
    columns; PostgreSQL rejects them (the #1093 DatatypeMismatch class).
    Anything that cannot be coerced losslessly fails loudly with context."""
    if value is None:
        return None
    if pg_type in INT_TYPES:
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, int):
            return value
        if isinstance(value, float):
            if value.is_integer():
                return int(value)
            raise EtlError(f"{ctx}: non-integral float {value!r} for {pg_type} column")
        if isinstance(value, str):
            try:
                return int(value.strip())
            except ValueError:
                raise EtlError(f"{ctx}: non-numeric string {value!r} for {pg_type} column")
        raise EtlError(f"{ctx}: {type(value).__name__} for {pg_type} column")
    if pg_type in TEXT_TYPES:
        if isinstance(value, str):
            return value
        if isinstance(value, bool):
            return str(int(value))
        if isinstance(value, (int, float)):
            return str(value)
        if isinstance(value, (bytes, memoryview)):
            try:
                return bytes(value).decode("utf-8")
            except UnicodeDecodeError:
                raise EtlError(f"{ctx}: undecodable bytes for text column")
        raise EtlError(f"{ctx}: {type(value).__name__} for text column")
    if pg_type in FLOAT_TYPES:
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, (int, float)):
            return value
        if isinstance(value, str):
            try:
                return float(value.strip())
            except ValueError:
                raise EtlError(f"{ctx}: non-numeric string {value!r} for {pg_type} column")
        raise EtlError(f"{ctx}: {type(value).__name__} for {pg_type} column")
    if pg_type == "bytea":
        if isinstance(value, (bytes, memoryview)):
            return psycopg2.Binary(bytes(value))
        if isinstance(value, str):
            return psycopg2.Binary(value.encode("utf-8"))
        raise EtlError(f"{ctx}: {type(value).__name__} for bytea column")
    return value


def main():
    if not SQLITE_PATH or not PG_URL:
        fail(1, "SQLITE_PATH and PG_URL env vars are required")

    lite = sqlite3.connect(f"file:{SQLITE_PATH}?mode=ro&immutable=1", uri=True)
    pg = psycopg2.connect(PG_URL)
    pg.autocommit = False
    cur = pg.cursor()

    lite_tables = {
        r[0] for r in lite.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
    }
    cur.execute(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_schema='public' AND table_type='BASE TABLE'")
    pg_tables = {r[0] for r in cur.fetchall()}

    drift = lite_tables - pg_tables - SQLITE_ONLY_OK
    # A SQLite table absent from the PG schema (which is built fresh from
    # schema.py at HEAD) is an orphan: created by an old additive SQLite
    # migration whose table was later dropped from the schema definition, but
    # SQLite never DROPped it from existing DBs. Skipping it is SAFE *iff it is
    # empty* — a fresh PG instance built from schema.py would never have it
    # either, so no data is lost. A NON-EMPTY drift table is real data at risk
    # and must hard-fail for investigation (genuine code/DB version mismatch).
    empty_drift, nonempty_drift = [], []
    for t in sorted(drift):
        n = lite.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
        (empty_drift if n == 0 else nonempty_drift).append(t)
    if nonempty_drift:
        fail(3, "SQLite tables missing in PostgreSQL schema but holding DATA "
                f"(code/DB version mismatch — investigate): {sorted(nonempty_drift)}")
    if empty_drift:
        print(f"  skipping empty orphaned tables (absent from PG schema, 0 rows): {empty_drift}")
    pg_only = sorted(pg_tables - lite_tables)
    copy_tables = sorted(lite_tables & pg_tables)

    # Build the copy plan; hard-fail on column drift before touching anything.
    plan = []
    for t in copy_tables:
        cur.execute(
            "SELECT column_name, data_type FROM information_schema.columns "
            "WHERE table_schema='public' AND table_name=%s", (t,))
        pg_cols = {r[0]: r[1] for r in cur.fetchall()}
        lite_cols = [r[1] for r in lite.execute(f'PRAGMA table_info("{t}")')]
        missing = [c for c in lite_cols if c not in pg_cols]
        if missing:
            fail(3, f'table "{t}": SQLite columns missing in PostgreSQL: {missing}')
        plan.append((t, lite_cols, pg_cols))

    if not VERIFY_ONLY:
        nonempty = []
        for t, _, _ in plan:
            cur.execute(f'SELECT COUNT(*) FROM "{t}"')
            if cur.fetchone()[0]:
                nonempty.append(t)
        if nonempty:
            fail(4, "PostgreSQL tables not empty — no partial merges; wipe + "
                    f"re-bootstrap the schema first: {nonempty}")

        for t, cols, pg_cols in plan:
            collist = ", ".join(f'"{c}"' for c in cols)
            src = lite.execute(f'SELECT {collist} FROM "{t}"')
            total = 0
            while True:
                rows = src.fetchmany(BATCH)
                if not rows:
                    break
                out = []
                for i, row in enumerate(rows):
                    out.append(tuple(
                        coerce(v, pg_cols[c], f"{t}.{c} (row ~{total + i + 1})")
                        for c, v in zip(cols, row)))
                psycopg2.extras.execute_values(
                    cur, f'INSERT INTO "{t}" ({collist}) VALUES %s',
                    out, page_size=BATCH)
                total += len(rows)
            print(f"  loaded {t}: {total} rows")

        # Reset SERIAL sequences: rows were inserted with explicit ids, so
        # every nextval is still at 1 and the first app insert would collide.
        cur.execute(
            "SELECT c.table_name, c.column_name, "
            "       pg_get_serial_sequence(quote_ident(c.table_name), c.column_name) "
            "FROM information_schema.columns c "
            "WHERE c.table_schema='public' AND c.column_default LIKE 'nextval(%'")
        for t, col, seq in cur.fetchall():
            if seq is None:
                continue
            cur.execute(f'SELECT MAX("{col}") FROM "{t}"')
            mx = cur.fetchone()[0]
            if mx is None:
                cur.execute("SELECT setval(%s, 1, false)", (seq,))
            else:
                cur.execute("SELECT setval(%s, %s, true)", (seq, mx))
        pg.commit()
        print("  sequences reset; transaction committed")

    print(f"\n{'table':<42} {'sqlite':>10} {'postgres':>10}")
    mismatches = 0
    for t in copy_tables:
        lc = lite.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
        cur.execute(f'SELECT COUNT(*) FROM "{t}"')
        pc = cur.fetchone()[0]
        flag = "" if lc == pc else "  << MISMATCH"
        if lc != pc:
            mismatches += 1
        print(f"{t:<42} {lc:>10} {pc:>10}{flag}")
    skipped = sorted(lite_tables & SQLITE_ONLY_OK)
    if skipped:
        print(f"\nskipped (sqlite-only, expected): {skipped}")
    if empty_drift:
        print(f"skipped (empty orphan, absent from PG schema): {empty_drift}")
    if pg_only:
        print(f"postgres-only tables (left empty): {pg_only}")
    if mismatches:
        fail(2, f"{mismatches} table(s) mismatched")
    print(f"\nETL OK: {len(copy_tables)} tables verified"
          + (" (verify-only)" if VERIFY_ONLY else ""))


if __name__ == "__main__":
    try:
        main()
    except EtlError as e:
        fail(4, str(e))
    except psycopg2.Error as e:
        fail(4, f"PostgreSQL error: {e}")
