#!/usr/bin/env python3
"""repair-dump.py — One-shot repair of a sanitized Paperclip dump (ADR-08/R8).

sync-export.sh excludes secret tables (company_secrets, agent_api_keys,
ai_connection_pools, user_secret_definitions, company_secret_versions) but
leaves rows in tables that reference them via FK. On import those rows
violate FK constraints and abort the restore.

This script parses the dump's schema (ADD CONSTRAINT ... FOREIGN KEY ...)
to find every referencing table/column against an excluded table, then
emulates the FK action on the COPY data:
  - ON DELETE CASCADE      -> drop the row
  - ON DELETE SET NULL     -> set the column to NULL
  - RESTRICT / NO ACTION   -> set the column to NULL (documented deviation;
                              the referenced rows were already excluded)

Usage: repair-dump.py <dump.sql>   (rewrites in place, then caller re-checksums)
"""
import re
import sys

EXCLUDED = {
    "company_secrets",
    "company_secret_versions",
    "agent_api_keys",
    "ai_connection_pools",
    "user_secret_definitions",
}

FK_RE = re.compile(
    r"ADD CONSTRAINT \w+ FOREIGN KEY \((?P<cols>[^)]+)\) "
    r"REFERENCES (?:public\.)?(?P<ref>\w+)\(?"  # optional column list
    r"(?P<cols2>[^)]*)\)?\s*(?P<action>ON DELETE \w+(?: \w+)?)?",
)

COPY_RE = re.compile(r"^COPY (?:public\.)?(\w+) \(([^)]*)\) FROM stdin;")

NULL = r"\N"


def main(path: str) -> None:
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()

    # 1. Schema pass: table -> {column: action}
    # NOTE: pg_dump splits the statement:
    #   ALTER TABLE ONLY public.<table>
    #       ADD CONSTRAINT ... FOREIGN KEY (...) REFERENCES ...;
    refs: dict[str, dict[str, str]] = {}
    alter_table_re = re.compile(r"^ALTER TABLE (?:ONLY )?(?:public\.)?(\w+)")
    current_table = None
    for line in lines:
        m_t = alter_table_re.match(line)
        if m_t:
            current_table = m_t.group(1)
            continue
        if "ADD CONSTRAINT" not in line or "FOREIGN KEY" not in line:
            continue
        m = FK_RE.search(line)
        if not m or m.group("ref") not in EXCLUDED:
            continue
        if not current_table:
            continue
        table = current_table
        cols = [c.strip().strip('"') for c in m.group("cols").split(",")]
        action = m.group("action") or ""
        for col in cols:
            if col in EXCLUDED:  # self-FK on excluded table, skip
                continue
            refs.setdefault(table, {}).setdefault(col, action)

    if not refs:
        print("no FK references to excluded tables found — dump is clean")
        return

    print("repair plan:")
    for table, cols in sorted(refs.items()):
        for col, action in sorted(cols.items()):
            print(f"  {table}.{col}  -> {action or 'NO ACTION'}")

    # 2. Data pass: rewrite COPY blocks
    out: list[str] = []
    i = 0
    stats: dict[tuple, int] = {}
    while i < len(lines):
        line = lines[i]
        m = COPY_RE.match(line)
        if not m or m.group(1) not in refs:
            out.append(line)
            i += 1
            continue

        table = m.group(1)
        header_cols = [c.strip().strip('"') for c in m.group(2).split(",")]
        col_actions = refs[table]

        out.append(line)
        i += 1
        while i < len(lines) and lines[i].rstrip("\n") != "\\.":
            row = lines[i].rstrip("\n")
            i += 1
            fields = split_row(row, len(header_cols))
            if fields is None:  # not a COPY-data-looking line; keep as-is
                out.append(row + "\n")
                continue

            drop = False
            for col, action in col_actions.items():
                if col not in header_cols:
                    continue
                idx = header_cols.index(col)
                if fields[idx] == NULL:
                    continue  # already NULL, FK-safe
                if "CASCADE" in action:
                    drop = True
                    stats[(table, col, "drop")] = stats.get((table, col, "drop"), 0) + 1
                    break
                # SET NULL / RESTRICT / NO ACTION -> null the column
                fields[idx] = NULL
                stats[(table, col, "null")] = stats.get((table, col, "null"), 0) + 1
            if not drop:
                out.append("\t".join(fields) + "\n")
        if i < len(lines):
            out.append(lines[i])  # the "\." terminator
            i += 1

    # 3. Report + write
    print("rows repaired:")
    for (table, col, op), n in sorted(stats.items()):
        print(f"  {table}.{col}: {op} x{n}")
    if not stats:
        print("  (no rows needed repair)")

    with open(path, "w", encoding="utf-8") as f:
        f.writelines(out)
    print(f"dump rewritten in place: {path}")


def split_row(row: str, n: int) -> list[str] | None:
    fields = row.split("\t")
    if len(fields) != n:
        return None
    return fields


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: repair-dump.py <dump.sql>")
    main(sys.argv[1])
