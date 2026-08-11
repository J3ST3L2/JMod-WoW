-- Fast, set-based item -> spell catalog linkage.
-- Creates spell placeholders only when no spell entity exists yet, then links
-- item spell slots and required-spell dependencies. Safe to re-run.

USE jmod;

SET @src_id := (
    SELECT id FROM catalog_sources WHERE source_key = 'azerothcore-world' LIMIT 1
);

-- Collect every non-zero spell referenced by item_template.
DROP TEMPORARY TABLE IF EXISTS tmp_item_spells;
CREATE TEMPORARY TABLE tmp_item_spells (
    spell_id BIGINT UNSIGNED NOT NULL PRIMARY KEY
) ENGINE=Memory;

INSERT IGNORE INTO tmp_item_spells (spell_id)
SELECT spell_id
FROM (
    SELECT spellid_1 AS spell_id FROM acore_world.item_template WHERE spellid_1 > 0
    UNION ALL SELECT spellid_2 FROM acore_world.item_template WHERE spellid_2 > 0
    UNION ALL SELECT spellid_3 FROM acore_world.item_template WHERE spellid_3 > 0
    UNION ALL SELECT spellid_4 FROM acore_world.item_template WHERE spellid_4 > 0
    UNION ALL SELECT spellid_5 FROM acore_world.item_template WHERE spellid_5 > 0
    UNION ALL SELECT requiredspell FROM acore_world.item_template WHERE requiredspell > 0
) AS s;

-- Placeholder spell entities. INSERT IGNORE deliberately preserves any spell
-- that has already been enriched from DBC/online/manual sources.
INSERT IGNORE INTO catalog_entities (
    entity_type, game_id, name, slug, short_description, source_id,
    source_record_id, verified, enabled, metadata, source_fetched_at
)
SELECT
    'spell',
    t.spell_id,
    CONCAT('Spell ', t.spell_id),
    CONCAT('spell-', t.spell_id),
    'Placeholder awaiting WotLK 3.3.5 DBC or online enrichment.',
    @src_id,
    CAST(t.spell_id AS CHAR),
    0,
    1,
    JSON_OBJECT('placeholder', TRUE, 'discovered_from', 'item_template'),
    UTC_TIMESTAMP()
FROM tmp_item_spells AS t;

-- Link each item spell slot to its spell entity. We keep the trigger and slot
-- number as relation metadata because they matter when interpreting items.
INSERT INTO catalog_relationships (from_entity_id, relation_type, to_entity_id, metadata)
SELECT ient.id, 'uses', sent.id,
       JSON_OBJECT('slot', x.slot_no, 'trigger', x.trigger_type)
FROM (
    SELECT entry, 1 AS slot_no, spellid_1 AS spell_id, spelltrigger_1 AS trigger_type
      FROM acore_world.item_template WHERE spellid_1 > 0
    UNION ALL
    SELECT entry, 2, spellid_2, spelltrigger_2 FROM acore_world.item_template WHERE spellid_2 > 0
    UNION ALL
    SELECT entry, 3, spellid_3, spelltrigger_3 FROM acore_world.item_template WHERE spellid_3 > 0
    UNION ALL
    SELECT entry, 4, spellid_4, spelltrigger_4 FROM acore_world.item_template WHERE spellid_4 > 0
    UNION ALL
    SELECT entry, 5, spellid_5, spelltrigger_5 FROM acore_world.item_template WHERE spellid_5 > 0
) AS x
JOIN catalog_entities AS ient
  ON ient.entity_type='item' AND ient.game_id=x.entry
JOIN catalog_entities AS sent
  ON sent.entity_type='spell' AND sent.game_id=x.spell_id
ON DUPLICATE KEY UPDATE metadata=VALUES(metadata);

-- Link item requiredspell values as explicit requirements.
INSERT INTO catalog_relationships (from_entity_id, relation_type, to_entity_id, metadata)
SELECT ient.id, 'requires', sent.id,
       JSON_OBJECT('source_field', 'requiredspell')
FROM acore_world.item_template AS i
JOIN catalog_entities AS ient
  ON ient.entity_type='item' AND ient.game_id=i.entry
JOIN catalog_entities AS sent
  ON sent.entity_type='spell' AND sent.game_id=i.requiredspell
WHERE i.requiredspell > 0
ON DUPLICATE KEY UPDATE metadata=VALUES(metadata);

-- Add searchable placeholder aliases without touching aliases added later by
-- higher-priority enrichment sources.
INSERT IGNORE INTO catalog_aliases (entity_id, alias, normalized_alias, alias_type)
SELECT e.id, e.name, LOWER(e.name), 'name'
FROM catalog_entities AS e
WHERE e.entity_type='spell'
  AND JSON_EXTRACT(e.metadata, '$.placeholder') = TRUE;

SELECT COUNT(*) AS catalog_spell_count
FROM catalog_entities
WHERE entity_type='spell';

SELECT COUNT(*) AS item_spell_relationship_count
FROM catalog_relationships AS r
JOIN catalog_entities AS e ON e.id=r.from_entity_id
WHERE e.entity_type='item'
  AND r.relation_type IN ('uses','requires');
