# JMod catalog strategy

JMod should never require an administrator to memorize WotLK numeric IDs, and
normal web/admin operations should not depend on a third-party website being
reachable at request time.

## Local catalog is the runtime source

All friendly lookups resolve through the `jmod` database. External sources are
used only to build or enrich that local catalog.

The unified entity catalog supports these types now:

- item
- spell
- mount
- training
- skill
- profession
- quest
- faction
- achievement
- title
- currency
- area
- teleport
- preset
- other

Each entity can store its game ID, friendly name, descriptions, aliases,
requirements, source provenance, source URL, verification state, and arbitrary
JSON metadata. Relationships connect entities such as mount items -> mount
spells, quest -> reward, or training profile -> spell.

## Source priority

1. **JMod manual override**: operator corrections and curated aliases.
2. **AzerothCore world DB**: server-compatible item/world IDs and metadata.
3. **Wrath 3.3.5 client DBC data**: complete spell/skill/area/faction/title data.
4. **Online WotLK metadata**: friendly descriptions, source information, and
   enrichment captured locally with provenance.

AzerothCore `item_template` is a complete local item-template source. Complete
spell names should come from client 3.3.5 `Spell.dbc` or an imported online
WotLK data export; `acore_world.spell_dbc` is not treated as the full spell
catalog.

## Why online data is enrichment instead of a runtime dependency

Third-party pages change markup, throttle requests, disappear, or return data
for a different game version. JMod therefore records the source and fetched
Date, stores the result locally, and executes actions using the locally stored
verified game ID.

A source URL can still be shown in the admin UI for provenance.

## Import workflow

Apply `database/migrations/20260810_1537_catalogs.sql`, configure least-
privilege `jmod` credentials, then run:

```bash
python3 tools/catalog_sync.py sync-items
python3 tools/catalog_sync.py sync-item-spells
```

`sync-items` imports every row from AzerothCore `item_template`, including the
friendly item name and tooltip description already present on the server.

`sync-item-spells` creates item-to-spell relationships and placeholder spell
entities for referenced spell IDs. Those placeholders are intentionally
replaced/enriched later from complete 3.3.5 spell data.

Any curated or online export can then be imported with:

```bash
python3 tools/catalog_sync.py import-json data.json --source-key online-wotlk
```

## JSON import format

The importer accepts a list, or an object containing a `records` list.

```json
{
  "records": [
    {
      "type": "mount",
      "game_id": 41252,
      "name": "Raven Lord",
      "short_description": "Ground mount",
      "description": "Friendly WotLK description captured from a source.",
      "category": "ground",
      "required_level": 40,
      "required_skill_id": 762,
      "required_skill_rank": 150,
      "aliases": ["raven", "anzu mount"],
      "source_key": "online-wotlk",
      "source_record_id": "41252",
      "source_url": "https://example.invalid/source/41252",
      "verified": true,
      "metadata": {
        "speed_percent": 100,
        "mount_item_id": 32768
      }
    }
  ]
}
```

The example URL is intentionally non-functional. Actual imports should record
the real source URL used by the importer/exporter.

## Training

Training profiles are stored separately because they are ordered collections
of spell entities. Examples can include `priest-trainer-80`, `riding-all`, or
custom JMod presets. Execution still uses the verified AzerothCore named-player
primitive:

```text
player learn <character> <spell-id>
```

The UI should select friendly spell or profile names and never expose spell
IDs unless the operator explicitly asks to see advanced details.
