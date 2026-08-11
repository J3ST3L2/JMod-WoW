-- Fast JMod teleport catalog sync from AzerothCore game_tele.
-- Uses the server's own named teleport destinations as the runtime source of truth.

USE jmod;

SET @source_id := (
    SELECT id
    FROM catalog_sources
    WHERE source_key = 'azerothcore-world'
    LIMIT 1
);

INSERT INTO catalog_entities (
    entity_type,
    game_id,
    name,
    slug,
    short_description,
    description,
    category,
    source_id,
    source_record_id,
    verified,
    enabled,
    metadata,
    source_fetched_at,
    last_verified_at
)
SELECT
    'teleport',
    gt.id,
    gt.name,
    LOWER(REPLACE(gt.name, ' ', '-')),
    CONCAT('Map ', gt.map),
    'Named AzerothCore fast-travel destination from acore_world.game_tele.',
    'world-teleport',
    @source_id,
    CAST(gt.id AS CHAR),
    1,
    1,
    JSON_OBJECT(
        'location_name', gt.name,
        'map_id', gt.map,
        'position_x', gt.position_x,
        'position_y', gt.position_y,
        'position_z', gt.position_z,
        'orientation', gt.orientation,
        'runtime_command', CONCAT('teleport name <character> ', gt.name)
    ),
    UTC_TIMESTAMP(),
    UTC_TIMESTAMP()
FROM acore_world.game_tele gt
ON DUPLICATE KEY UPDATE
    name = VALUES(name),
    slug = VALUES(slug),
    short_description = VALUES(short_description),
    description = VALUES(description),
    category = VALUES(category),
    source_id = VALUES(source_id),
    source_record_id = VALUES(source_record_id),
    verified = VALUES(verified),
    enabled = VALUES(enabled),
    metadata = VALUES(metadata),
    source_fetched_at = VALUES(source_fetched_at),
    last_verified_at = VALUES(last_verified_at);

INSERT INTO catalog_aliases (entity_id, alias, normalized_alias, alias_type)
SELECT
    ce.id,
    ce.name,
    LOWER(TRIM(REGEXP_REPLACE(ce.name, '[[:space:]]+', ' '))),
    'name'
FROM catalog_entities ce
WHERE ce.entity_type = 'teleport'
  AND ce.enabled = 1
ON DUPLICATE KEY UPDATE
    alias = VALUES(alias),
    alias_type = VALUES(alias_type);

SELECT COUNT(*) AS catalog_teleport_count
FROM catalog_entities
WHERE entity_type = 'teleport';
