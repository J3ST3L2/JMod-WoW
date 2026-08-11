#!/usr/bin/env python3
"""Derive WotLK 3.3.5 mount catalog entries from Spell.dbc.

A mount spell is identified by an APPLY_AURA effect (6) whose aura is
SPELL_AURA_MOUNTED (78). The mount entity game_id is the learnable spell ID.

Usage:
    python3 tools/dbc_mounts_to_sql.py data/dbc/Spell.dbc \
      | docker exec -i ac-database sh -lc 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

EXPECTED_FIELDS = 234
EXPECTED_RECORD_SIZE = 936

IDX_ID = 0
IDX_SPELL_LEVEL = 39
IDX_EFFECT = (71, 72, 73)
IDX_EFFECT_AURA = (95, 96, 97)
IDX_EFFECT_MISC = (110, 111, 112)
IDX_NAME_0 = 136
IDX_RANK_0 = 153
IDX_DESCRIPTION_0 = 170
IDX_TOOLTIP_0 = 187

SPELL_EFFECT_APPLY_AURA = 6
SPELL_AURA_MOUNTED = 78


def sql_string(value: str | None) -> str:
    if value is None:
        return "NULL"
    value = (
        value.replace("\\", "\\\\")
        .replace("\0", "\\0")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\x1a", "\\Z")
        .replace("'", "\\'")
    )
    return "'" + value + "'"


def slugify(value: str) -> str:
    out: list[str] = []
    dash = False
    for ch in value.lower():
        if ch.isascii() and ch.isalnum():
            if dash and out:
                out.append("-")
            out.append(ch)
            dash = False
        else:
            dash = True
    return "".join(out)[:255]


def read_cstring(block: bytes, offset: int) -> str:
    if offset <= 0 or offset >= len(block):
        return ""
    end = block.find(b"\x00", offset)
    if end < 0:
        end = len(block)
    return block[offset:end].decode("utf-8", errors="replace").strip()


def iter_mounts(path: Path):
    data = path.read_bytes()
    if len(data) < 20 or data[:4] != b"WDBC":
        raise SystemExit("Not a WDBC file")

    records, fields, record_size, string_size = struct.unpack_from("<4I", data, 4)
    expected_size = 20 + records * record_size + string_size
    if fields != EXPECTED_FIELDS or record_size != EXPECTED_RECORD_SIZE:
        raise SystemExit(
            f"Unexpected Spell.dbc layout: {fields} fields / {record_size} bytes"
        )
    if expected_size != len(data):
        raise SystemExit(
            f"DBC size mismatch: expected {expected_size}, got {len(data)}"
        )

    records_start = 20
    strings_start = records_start + records * record_size
    strings = data[strings_start:]
    fmt = "<" + "I" * fields

    for i in range(records):
        row = struct.unpack_from(fmt, data, records_start + i * record_size)
        mounted_slots = [
            slot
            for slot in range(3)
            if int(row[IDX_EFFECT[slot]]) == SPELL_EFFECT_APPLY_AURA
            and int(row[IDX_EFFECT_AURA[slot]]) == SPELL_AURA_MOUNTED
        ]
        if not mounted_slots:
            continue

        spell_id = int(row[IDX_ID])
        name = read_cstring(strings, row[IDX_NAME_0]) or f"Mount {spell_id}"
        rank = read_cstring(strings, row[IDX_RANK_0])
        description = read_cstring(strings, row[IDX_DESCRIPTION_0])
        tooltip = read_cstring(strings, row[IDX_TOOLTIP_0])
        display_ids = [int(row[IDX_EFFECT_MISC[s]]) for s in mounted_slots]

        yield {
            "id": spell_id,
            "name": name,
            "slug": slugify(name),
            "rank": rank or None,
            "description": description or None,
            "required_level": int(row[IDX_SPELL_LEVEL]) or None,
            "metadata": {
                "spell_id": spell_id,
                "rank": rank or None,
                "tooltip": tooltip or None,
                "mounted_effect_slots": [s + 1 for s in mounted_slots],
                "mount_display_ids": display_ids,
                "classification": "spell_aura_mounted",
            },
        }


def emit_batch(batch: list[dict]) -> None:
    if not batch:
        return

    print(
        "INSERT INTO catalog_entities ("
        "entity_type,game_id,name,slug,short_description,description,required_level,"
        "source_id,source_record_id,verified,enabled,metadata,source_fetched_at,last_verified_at"
        ") VALUES"
    )
    rows = []
    for rec in batch:
        rows.append(
            "(" + ",".join(
                [
                    "'mount'",
                    str(rec["id"]),
                    sql_string(rec["name"]),
                    sql_string(rec["slug"]),
                    sql_string(rec["rank"]),
                    sql_string(rec["description"]),
                    "NULL" if rec["required_level"] is None else str(rec["required_level"]),
                    "@dbc_source_id",
                    sql_string(str(rec["id"])),
                    "1",
                    "1",
                    sql_string(json.dumps(rec["metadata"], ensure_ascii=False, separators=(",", ":"))),
                    "UTC_TIMESTAMP()",
                    "UTC_TIMESTAMP()",
                ]
            ) + ")"
        )
    print(",\n".join(rows))
    print(
        "ON DUPLICATE KEY UPDATE "
        "name=VALUES(name),slug=VALUES(slug),short_description=VALUES(short_description),"
        "description=VALUES(description),required_level=VALUES(required_level),"
        "source_id=VALUES(source_id),source_record_id=VALUES(source_record_id),"
        "verified=VALUES(verified),enabled=VALUES(enabled),metadata=VALUES(metadata),"
        "source_fetched_at=VALUES(source_fetched_at),last_verified_at=VALUES(last_verified_at);"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dbc", type=Path)
    parser.add_argument("--batch-size", type=int, default=500)
    args = parser.parse_args()

    print("SET NAMES utf8mb4;")
    print("USE jmod;")
    print(
        "SET @dbc_source_id := (SELECT id FROM catalog_sources "
        "WHERE source_key='wotlk-client-dbc' LIMIT 1);"
    )

    count = 0
    batch: list[dict] = []
    for mount in iter_mounts(args.dbc):
        count += 1
        batch.append(mount)
        if len(batch) >= args.batch_size:
            emit_batch(batch)
            batch.clear()
    emit_batch(batch)

    print(
        "INSERT INTO catalog_aliases (entity_id,alias,normalized_alias,alias_type) "
        "SELECT id,name,LOWER(TRIM(REGEXP_REPLACE(name,'[[:space:]]+',' '))),'name' "
        "FROM catalog_entities WHERE entity_type='mount' AND enabled=1 "
        "ON DUPLICATE KEY UPDATE alias=VALUES(alias),alias_type=VALUES(alias_type);"
    )

    # Mount entity uses the corresponding spell entity with the same game ID.
    print(
        "INSERT INTO catalog_relationships (from_entity_id,relation_type,to_entity_id,metadata) "
        "SELECT m.id,'uses',s.id,JSON_OBJECT('source','Spell.dbc','spell_id',m.game_id) "
        "FROM catalog_entities m JOIN catalog_entities s "
        "ON s.entity_type='spell' AND s.game_id=m.game_id "
        "WHERE m.entity_type='mount' "
        "ON DUPLICATE KEY UPDATE metadata=VALUES(metadata);"
    )

    print(
        "SELECT COUNT(*) AS catalog_mount_count, "
        "SUM(name NOT LIKE 'Mount %') AS friendly_mount_name_count "
        "FROM catalog_entities WHERE entity_type='mount';"
    )
    print(f"-- Derived {count} mounted-aura spells", file=sys.stderr)


if __name__ == "__main__":
    main()
