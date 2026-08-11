#!/usr/bin/env python3
"""Populate the JMod local catalog from AzerothCore and curated/online exports.

The UI should query jmod.catalog_* only. External sites are import/enrichment
sources, never runtime dependencies for admin actions.

Examples:
    python3 tools/catalog_sync.py sync-items
    python3 tools/catalog_sync.py sync-item-spells
    python3 tools/catalog_sync.py import-json tools/catalog_sources/example.json

Environment variables:
    JMOD_DB_HOST / WOW_DB_HOST               default: 127.0.0.1
    JMOD_DB_PORT / WOW_DB_PORT               default: 3306
    JMOD_DB_USER                             required
    JMOD_DB_PASSWORD                         required
    JMOD_DB_NAME                             default: jmod
    WOW_SOURCE_DB_USER / WOW_DB_USER         defaults to JMOD_DB_USER
    WOW_SOURCE_DB_PASSWORD / WOW_DB_PASSWORD defaults to JMOD_DB_PASSWORD
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

import pymysql

ENTITY_TYPES = {
    "item", "spell", "mount", "training", "skill", "profession", "quest",
    "faction", "achievement", "title", "currency", "area", "teleport",
    "preset", "other",
}


def env(*names: str, default: str | None = None, required: bool = False) -> str:
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    if required:
        raise SystemExit(f"Missing required environment variable: {' or '.join(names)}")
    return default or ""


def connect(*, database: str, write: bool = False):
    user = env("JMOD_DB_USER", required=write)
    password = env("JMOD_DB_PASSWORD", required=write)
    if not write:
        user = env("WOW_SOURCE_DB_USER", "WOW_DB_USER", "JMOD_DB_USER", required=True)
        password = env("WOW_SOURCE_DB_PASSWORD", "WOW_DB_PASSWORD", "JMOD_DB_PASSWORD", required=True)
    return pymysql.connect(
        host=env("JMOD_DB_HOST", "WOW_DB_HOST", default="127.0.0.1"),
        port=int(env("JMOD_DB_PORT", "WOW_DB_PORT", default="3306")),
        user=user,
        password=password,
        database=database,
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
        charset="utf8mb4",
    )


def normalize(value: str) -> str:
    return " ".join((value or "").strip().lower().split())


def slugify(value: str) -> str:
    value = normalize(value)
    value = re.sub(r"[^a-z0-9]+", "-", value).strip("-")
    return value[:255]


def source_id(conn, source_key: str) -> int:
    with conn.cursor() as cur:
        cur.execute("SELECT id FROM catalog_sources WHERE source_key=%s", (source_key,))
        row = cur.fetchone()
        if not row:
            raise RuntimeError(f"catalog source {source_key!r} does not exist; apply the catalog migration first")
        return int(row["id"])


def upsert_entity(conn, record: dict[str, Any], *, default_source_key: str) -> tuple[int, bool]:
    entity_type = str(record.get("type") or record.get("entity_type") or "").strip().lower()
    if entity_type not in ENTITY_TYPES:
        raise ValueError(f"Unsupported entity type: {entity_type!r}")

    game_id = record.get("game_id")
    if game_id in ("", None):
        game_id = None
    elif not isinstance(game_id, int):
        game_id = int(game_id)

    name = str(record.get("name") or "").strip()
    if not name:
        raise ValueError("Catalog record is missing name")

    src_key = str(record.get("source_key") or default_source_key)
    src_id = source_id(conn, src_key)
    metadata = record.get("metadata") or {}
    source_fetched_at = record.get("source_fetched_at") or datetime.now(timezone.utc).replace(tzinfo=None)

    with conn.cursor() as cur:
        existing = None
        if game_id is not None:
            cur.execute(
                "SELECT id FROM catalog_entities WHERE entity_type=%s AND game_id=%s",
                (entity_type, game_id),
            )
            existing = cur.fetchone()

        values = (
            name,
            record.get("slug") or slugify(name),
            record.get("short_description"),
            record.get("description"),
            record.get("icon"),
            record.get("category"),
            record.get("subcategory"),
            record.get("required_level"),
            record.get("required_skill_id"),
            record.get("required_skill_rank"),
            record.get("class_mask"),
            record.get("race_mask"),
            record.get("quality"),
            src_id,
            record.get("source_record_id") or (str(game_id) if game_id is not None else None),
            record.get("source_url"),
            1 if record.get("verified") else 0,
            0 if record.get("enabled") is False else 1,
            json.dumps(metadata, ensure_ascii=False),
            source_fetched_at,
            record.get("last_verified_at"),
        )

        if existing:
            cur.execute(
                """
                UPDATE catalog_entities SET
                    name=%s, slug=%s, short_description=%s, description=%s,
                    icon=%s, category=%s, subcategory=%s, required_level=%s,
                    required_skill_id=%s, required_skill_rank=%s,
                    class_mask=%s, race_mask=%s, quality=%s, source_id=%s,
                    source_record_id=%s, source_url=%s, verified=%s, enabled=%s,
                    metadata=%s, source_fetched_at=%s, last_verified_at=%s
                WHERE id=%s
                """,
                values + (existing["id"],),
            )
            entity_id = int(existing["id"])
            inserted = False
        else:
            cur.execute(
                """
                INSERT INTO catalog_entities (
                    entity_type, game_id, name, slug, short_description, description,
                    icon, category, subcategory, required_level, required_skill_id,
                    required_skill_rank, class_mask, race_mask, quality, source_id,
                    source_record_id, source_url, verified, enabled, metadata,
                    source_fetched_at, last_verified_at
                ) VALUES (
                    %s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s
                )
                """,
                (entity_type, game_id) + values,
            )
            entity_id = int(cur.lastrowid)
            inserted = True

        aliases = set(record.get("aliases") or [])
        aliases.add(name)
        for alias in aliases:
            alias = str(alias).strip()
            if not alias:
                continue
            cur.execute(
                """
                INSERT INTO catalog_aliases (entity_id, alias, normalized_alias, alias_type)
                VALUES (%s,%s,%s,%s)
                ON DUPLICATE KEY UPDATE alias=VALUES(alias)
                """,
                (entity_id, alias, normalize(alias), "name" if alias == name else "search"),
            )

    return entity_id, inserted


def iter_item_records(src) -> Iterable[dict[str, Any]]:
    with src.cursor() as cur:
        cur.execute(
            """
            SELECT entry, name, description, class, subclass, Quality, ItemLevel,
                   RequiredLevel, RequiredSkill, RequiredSkillRank, requiredspell,
                   AllowableClass, AllowableRace, InventoryType, bonding, displayid,
                   spellid_1, spelltrigger_1, spellid_2, spelltrigger_2,
                   spellid_3, spelltrigger_3, spellid_4, spelltrigger_4,
                   spellid_5, spelltrigger_5, VerifiedBuild
            FROM acore_world.item_template
            ORDER BY entry
            """
        )
        for row in cur:
            spell_slots = []
            for n in range(1, 6):
                spell_id = int(row.get(f"spellid_{n}") or 0)
                trigger = int(row.get(f"spelltrigger_{n}") or 0)
                if spell_id:
                    spell_slots.append({"slot": n, "spell_id": spell_id, "trigger": trigger})
            yield {
                "type": "item",
                "game_id": int(row["entry"]),
                "name": row["name"],
                "description": row.get("description") or None,
                "category": f"class:{row['class']}",
                "subcategory": f"subclass:{row['subclass']}",
                "quality": int(row.get("Quality") or 0),
                "required_level": int(row.get("RequiredLevel") or 0) or None,
                "required_skill_id": int(row.get("RequiredSkill") or 0) or None,
                "required_skill_rank": int(row.get("RequiredSkillRank") or 0) or None,
                "class_mask": int(row.get("AllowableClass") or -1),
                "race_mask": int(row.get("AllowableRace") or -1),
                "verified": int(row.get("VerifiedBuild") or 0) > 0,
                "source_key": "azerothcore-world",
                "metadata": {
                    "item_level": int(row.get("ItemLevel") or 0),
                    "inventory_type": int(row.get("InventoryType") or 0),
                    "bonding": int(row.get("bonding") or 0),
                    "display_id": int(row.get("displayid") or 0),
                    "required_spell": int(row.get("requiredspell") or 0),
                    "verified_build": int(row.get("VerifiedBuild") or 0),
                    "spell_slots": spell_slots,
                },
            }


def sync_items() -> None:
    src = connect(database="acore_world", write=False)
    dst = connect(database=env("JMOD_DB_NAME", default="jmod"), write=True)
    inserted = updated = failed = 0
    try:
        for record in iter_item_records(src):
            try:
                _, is_new = upsert_entity(dst, record, default_source_key="azerothcore-world")
                inserted += int(is_new)
                updated += int(not is_new)
            except Exception as exc:
                failed += 1
                print(f"item {record.get('game_id')}: {exc}", file=sys.stderr)
        print(json.dumps({"type": "item", "inserted": inserted, "updated": updated, "failed": failed}))
    finally:
        src.close()
        dst.close()


def sync_item_spells() -> None:
    """Create spell placeholders + item->spell relationships for item spell slots.

    This intentionally does not pretend AzerothCore spell_dbc is a complete
    spell catalog. Names/descriptions are later enriched from 3.3.5 DBC or
    imported online metadata.
    """
    dst = connect(database=env("JMOD_DB_NAME", default="jmod"), write=True)
    created_spells = relationships = 0
    try:
        with dst.cursor() as cur:
            cur.execute(
                """
                SELECT id, game_id, metadata
                FROM catalog_entities
                WHERE entity_type='item' AND enabled=1
                """
            )
            items = list(cur.fetchall())

        for item in items:
            raw = item.get("metadata")
            metadata = json.loads(raw) if isinstance(raw, str) else (raw or {})
            for slot in metadata.get("spell_slots") or []:
                spell_id = int(slot.get("spell_id") or 0)
                if not spell_id:
                    continue
                spell_entity_id, is_new = upsert_entity(
                    dst,
                    {
                        "type": "spell",
                        "game_id": spell_id,
                        "name": f"Spell {spell_id}",
                        "short_description": "Placeholder awaiting WotLK 3.3.5 DBC or online enrichment.",
                        "source_key": "azerothcore-world",
                        "metadata": {"placeholder": True},
                    },
                    default_source_key="azerothcore-world",
                )
                created_spells += int(is_new)
                with dst.cursor() as cur:
                    cur.execute(
                        """
                        INSERT INTO catalog_relationships
                            (from_entity_id, relation_type, to_entity_id, metadata)
                        VALUES (%s,'uses',%s,%s)
                        ON DUPLICATE KEY UPDATE metadata=VALUES(metadata)
                        """,
                        (item["id"], spell_entity_id, json.dumps(slot)),
                    )
                    relationships += 1
        print(json.dumps({"created_spell_placeholders": created_spells, "relationships": relationships}))
    finally:
        dst.close()


def import_json(path: Path, source_key: str) -> None:
    payload = json.loads(path.read_text(encoding="utf-8"))
    records = payload.get("records") if isinstance(payload, dict) else payload
    if not isinstance(records, list):
        raise SystemExit("JSON must be a list or an object containing a records list")

    dst = connect(database=env("JMOD_DB_NAME", default="jmod"), write=True)
    inserted = updated = failed = 0
    try:
        for record in records:
            try:
                _, is_new = upsert_entity(dst, record, default_source_key=source_key)
                inserted += int(is_new)
                updated += int(not is_new)
            except Exception as exc:
                failed += 1
                print(f"record {record!r}: {exc}", file=sys.stderr)
        print(json.dumps({"inserted": inserted, "updated": updated, "failed": failed}))
    finally:
        dst.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("sync-items", help="Import all AzerothCore item_template rows")
    sub.add_parser("sync-item-spells", help="Create item->spell links and spell placeholders")
    p_json = sub.add_parser("import-json", help="Import/enrich any catalog entity type from JSON")
    p_json.add_argument("path", type=Path)
    p_json.add_argument("--source-key", default="online-wotlk")
    args = parser.parse_args()

    if args.command == "sync-items":
        sync_items()
    elif args.command == "sync-item-spells":
        sync_item_spells()
    elif args.command == "import-json":
        import_json(args.path, args.source_key)


if __name__ == "__main__":
    main()
