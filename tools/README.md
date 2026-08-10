# Tools

Utility scripts in this directory will build and refresh JMod catalogs from authoritative AzerothCore/WotLK data.

Planned tools:

- `discover_schema.py` - report relevant AzerothCore tables/columns without secrets
- `import_items.py` - refresh `jmod.item_catalog` from `acore_world.item_template`
- `import_spells.py` - refresh searchable spell metadata from available DBC-backed data
- `import_mounts.py` - build the mount catalog with spell IDs, item IDs, aliases, faction, and categories
- `import_training.py` - discover trainer relationships and produce training packages
- `rebuild_catalogs.py` - run all safe catalog refreshes

Importers should be repeatable and should never mutate normal AzerothCore game state.
