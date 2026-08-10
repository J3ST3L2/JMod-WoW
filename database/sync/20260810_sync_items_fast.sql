-- Fast, set-based import of AzerothCore items into the JMod catalog.
-- Safe to re-run. Existing rows are updated by (entity_type, game_id).

USE jmod;

SET @src_id := (
    SELECT id FROM catalog_sources WHERE source_key = 'azerothcore-world' LIMIT 1
);

INSERT INTO catalog_entities (
    entity_type,
    game_id,
    name,
    slug,
    short_description,
    description,
    icon,
    category,
    subcategory,
    required_level,
    required_skill_id,
    required_skill_rank,
    class_mask,
    race_mask,
    quality,
    source_id,
    source_record_id,
    source_url,
    verified,
    enabled,
    metadata,
    source_fetched_at,
    last_verified_at
)
SELECT
    'item',
    i.entry,
    i.name,
    LEFT(TRIM(BOTH '-' FROM REGEXP_REPLACE(LOWER(i.name), '[^a-z0-9]+', '-')), 255),
    NULL,
    NULLIF(i.description, ''),
    NULL,
    CONCAT('class:', i.class),
    CONCAT('subclass:', i.subclass),
    NULLIF(i.RequiredLevel, 0),
    NULLIF(i.RequiredSkill, 0),
    NULLIF(i.RequiredSkillRank, 0),
    i.AllowableClass,
    i.AllowableRace,
    i.Quality,
    @src_id,
    CAST(i.entry AS CHAR),
    NULL,
    IF(i.VerifiedBuild > 0, 1, 0),
    1,
    JSON_OBJECT(
        'item_level', i.ItemLevel,
        'inventory_type', i.InventoryType,
        'bonding', i.bonding,
        'display_id', i.displayid,
        'required_spell', i.requiredspell,
        'verified_build', i.VerifiedBuild,
        'spell_slots', JSON_ARRAY(
            JSON_OBJECT('slot',1,'spell_id',i.spellid_1,'trigger',i.spelltrigger_1),
            JSON_OBJECT('slot',2,'spell_id',i.spellid_2,'trigger',i.spelltrigger_2),
            JSON_OBJECT('slot',3,'spell_id',i.spellid_3,'trigger',i.spelltrigger_3),
            JSON_OBJECT('slot',4,'spell_id',i.spellid_4,'trigger',i.spelltrigger_4),
            JSON_OBJECT('slot',5,'spell_id',i.spellid_5,'trigger',i.spelltrigger_5)
        )
    ),
    UTC_TIMESTAMP(),
    IF(i.VerifiedBuild > 0, UTC_TIMESTAMP(), NULL)
FROM acore_world.item_template AS i
ON DUPLICATE KEY UPDATE
    name = VALUES(name),
    slug = VALUES(slug),
    description = VALUES(description),
    category = VALUES(category),
    subcategory = VALUES(subcategory),
    required_level = VALUES(required_level),
    required_skill_id = VALUES(required_skill_id),
    required_skill_rank = VALUES(required_skill_rank),
    class_mask = VALUES(class_mask),
    race_mask = VALUES(race_mask),
    quality = VALUES(quality),
    source_id = VALUES(source_id),
    source_record_id = VALUES(source_record_id),
    verified = VALUES(verified),
    enabled = VALUES(enabled),
    metadata = VALUES(metadata),
    source_fetched_at = VALUES(source_fetched_at),
    last_verified_at = VALUES(last_verified_at);

INSERT INTO catalog_aliases (entity_id, alias, normalized_alias, alias_type)
SELECT
    e.id,
    e.name,
    LOWER(TRIM(REGEXP_REPLACE(e.name, '[[:space:]]+', ' '))),
    'name'
FROM catalog_entities AS e
WHERE e.entity_type = 'item'
  AND e.enabled = 1
ON DUPLICATE KEY UPDATE
    alias = VALUES(alias),
    alias_type = VALUES(alias_type);

SELECT COUNT(*) AS catalog_item_count
FROM catalog_entities
WHERE entity_type = 'item';
