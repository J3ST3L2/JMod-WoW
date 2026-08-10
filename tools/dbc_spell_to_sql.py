#!/usr/bin/env python3
"""Convert a Wrath 3.3.5 Spell.dbc into bulk SQL for the JMod catalog.

Usage:
    python3 tools/dbc_spell_to_sql.py data/dbc/Spell.dbc \
      | docker exec -i ac-database sh -lc 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'

The parser targets the 3.3.5 Spell.dbc layout documented by AzerothCore:
234 fields, 936-byte records. Locale slot 0 is used for the primary friendly
name, rank, description, and tooltip.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

EXPECTED_FIELDS = 234
EXPECTED_RECORD_SIZE = 936

# Spell.dbc 3.3.5 field indexes.
IDX_ID = 0
IDX_CATEGORY = 1
IDX_MAX_LEVEL = 37
IDX_BASE_LEVEL = 38
IDX_SPELL_LEVEL = 39
IDX_SPELL_ICON_ID = 133
IDX_ACTIVE_ICON_ID = 134
IDX_NAME_0 = 136
IDX_RANK_0 = 153
IDX_DESCRIPTION_0 = 170
IDX_TOOLTIP_0 = 187
IDX_SPELL_FAMILY_NAME = 208
IDX_MAX_AFFECTED_TARGETS = 212
IDX_DMG_CLASS = 213
IDX_PREVENTION_TYPE = 214
IDX_SCHOOL_MASK = 225
IDX_RUNE_COST_ID = 226
IDX_SPELL_DIFFICULTY_ID = 233


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
    out = []
    pending_dash = False
    for ch in value.lower():
        if "a" <= ch <= "z" or "0" <= ch <= "9":
            if pending_dash and out:
                out.append("-")
            out.append(ch)
            pending_dash = False
        else:
            pending_dash = True
    return "".join(out)[:255]


def read_cstring(block: bytes, offset: int) -> str:
    if offset <= 0 or offset >= len(block):
        return ""
    end = block.find(b"\x00", offset)
    if end < 0:
        end = len(block)
    return block[offset:end].decode("utf-8", errors="replace")


def iter_spells(path: Path):
    data = path.read_bytes()
    if len(data) < 20:
        raise SystemExit("DBC is too small")

    magic = data[:4]
    if magic != b"WDBC":
        raise SystemExit(f"Unsupported DBC magic: {magic!r}")

    records, fields, record_size, string_size = struct.unpack_from("<4I", data, 4)
    expected_size = 20 + records * record_size + string_size

    if fields != EXPECTED_FIELDS or record_size != EXPECTED_RECORD_SIZE:
        raise SystemExit(
            f"Unexpected Spell.dbc layout: fields={fields}, record_size={record_size}; "
            f"expected {EXPECTED_FIELDS}/{EXPECTED_RECORD_SIZE} for WotLK 3.3.5"
        )
    if expected_size != len(data):
        raise SystemExit(
            f"DBC size mismatch: header implies {expected_size} bytes, file has {len(data)}"
        )

    records_start = 20
    strings_start = records_start + records * record_size
    strings = data[strings_start:]
    fmt = "<" + "I" * fields

    for i in range(records):
        offset = records_start + i * record_size
        row = struct.unpack_from(fmt, data, offset)

        spell_id = int(row[IDX_ID])
        name = read_cstring(strings, row[IDX_NAME_0]).strip()
        rank = read_cstring(strings, row[IDX_RANK_0]).strip()
        description = read_cstring(strings, row[IDX_DESCRIPTION_0]).strip()
        tooltip = read_cstring(strings, row[IDX_TOOLTIP_0]).strip()

        # Some internal rows can have no localized name. Keep a searchable,
        # deterministic fallback rather than discarding a valid spell ID.
        if not name:
            name = f"Spell {spell_id}"

        metadata = {
            "rank": rank or None,
            "tooltip": tooltip or None,
            "category": int(row[IDX_CATEGORY]),
            "base_level": int(row[IDX_BASE_LEVEL]),
            "max_level": int(row[IDX_MAX_LEVEL]),
            "spell_level": int(row[IDX_SPELL_LEVEL]),
            "spell_icon_id": int(row[IDX_SPELL_ICON_ID]),
            "active_icon_id": int(row[IDX_ACTIVE_ICON_ID]),
            "spell_family_name": int(row[IDX_SPELL_FAMILY_NAME]),
            "max_affected_targets": int(row[IDX_MAX_AFFECTED_TARGETS]),
            "damage_class": int(row[IDX_DMG_CLASS]),
            "prevention_type": int(row[IDX_PREVENTION_TYPE]),
            "school_mask": int(row[IDX_SCHOOL_MASK]),
            "rune_cost_id": int(row[IDX_RUNE_COST_ID]),
            "spell_difficulty_id": int(row[IDX_SPELL_DIFFICULTY_ID]),
        }

        yield {
            "id": spell_id,
            "name": name,
            "rank": rank,
            "description": description or None,
            "slug": slugify(name),
            "required_level": int(row[IDX_SPELL_LEVEL]) or None,
            "metadata": metadata,
        }


def emit_batch(batch: list[dict]) -> None:
    if not batch:
        return

    print(
        "INSERT INTO catalog_entities ("
        "entity_type,game_id,name,slug,short_description,description,"
        "required_level,source_id,source_record_id,verified,enabled,metadata,"
        "source_fetched_at,last_verified_at) VALUES"
    )

    rows = []
    for rec in batch:
        short_description = rec["rank"] or None
        metadata_json = json.dumps(rec["metadata"], ensure_ascii=False, separators=(",", ":"))
        rows.append(
            "(" + ",".join(
                [
                    "'spell'",
                    str(rec["id"]),
                    sql_string(rec["name"]),
                    sql_string(rec["slug"]),
                    sql_string(short_description),
                    sql_string(rec["description"]),
                    "NULL" if rec["required_level"] is None else str(rec["required_level"]),
                    "@dbc_source_id",
                    sql_string(str(rec["id"])),
                    "1",
                    "1",
                    sql_string(metadata_json),
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

    if args.batch_size < 1:
        raise SystemExit("--batch-size must be at least 1")

    print("SET NAMES utf8mb4;")
    print("USE jmod;")
    print(
        "SET @dbc_source_id := (SELECT id FROM catalog_sources "
        "WHERE source_key='wotlk-client-dbc' LIMIT 1);"
    )
    print("SET @old_unique_checks := @@UNIQUE_CHECKS;")
    print("SET UNIQUE_CHECKS=0;")

    count = 0
    batch: list[dict] = []
    for spell in iter_spells(args.dbc):
        batch.append(spell)
        count += 1
        if len(batch) >= args.batch_size:
            emit_batch(batch)
            batch.clear()
    emit_batch(batch)

    # Refresh primary searchable names after the spell upserts.
    print(
        "INSERT INTO catalog_aliases (entity_id,alias,normalized_alias,alias_type) "
        "SELECT id,name,LOWER(TRIM(REGEXP_REPLACE(name,'[[:space:]]+',' '))),'name' "
        "FROM catalog_entities WHERE entity_type='spell' AND enabled=1 "
        "ON DUPLICATE KEY UPDATE alias=VALUES(alias),alias_type=VALUES(alias_type);"
    )
    print("SET UNIQUE_CHECKS=@old_unique_checks;")
    print(
        "SELECT COUNT(*) AS catalog_spell_count, "
        "SUM(name NOT LIKE 'Spell %') AS friendly_spell_name_count "
        "FROM catalog_entities WHERE entity_type='spell';"
    )

    print(f"-- Parsed {count} Spell.dbc records", file=sys.stderr)


if __name__ == "__main__":
    main()
