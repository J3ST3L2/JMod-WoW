-- JMod unified catalog schema
-- Stores friendly names, descriptions, IDs, aliases, provenance, and relationships
-- for all admin-visible WotLK entities without making the UI depend on live websites.

CREATE DATABASE IF NOT EXISTS jmod
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE jmod;

CREATE TABLE IF NOT EXISTS catalog_sources (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    source_key VARCHAR(64) NOT NULL,
    display_name VARCHAR(128) NOT NULL,
    source_type ENUM('azerothcore','dbc','online','manual','generated') NOT NULL,
    base_url VARCHAR(512) NULL,
    priority SMALLINT NOT NULL DEFAULT 100,
    enabled TINYINT(1) NOT NULL DEFAULT 1,
    notes TEXT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_catalog_sources_key (source_key)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS catalog_entities (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    entity_type ENUM(
        'item','spell','mount','training','skill','profession','quest','faction',
        'achievement','title','currency','area','teleport','preset','other'
    ) NOT NULL,
    game_id BIGINT UNSIGNED NULL,
    name VARCHAR(255) NOT NULL,
    slug VARCHAR(255) NULL,
    short_description VARCHAR(500) NULL,
    description TEXT NULL,
    icon VARCHAR(255) NULL,
    category VARCHAR(128) NULL,
    subcategory VARCHAR(128) NULL,
    required_level SMALLINT UNSIGNED NULL,
    required_skill_id INT UNSIGNED NULL,
    required_skill_rank SMALLINT UNSIGNED NULL,
    class_mask BIGINT SIGNED NULL,
    race_mask BIGINT SIGNED NULL,
    quality SMALLINT NULL,
    source_id BIGINT UNSIGNED NULL,
    source_record_id VARCHAR(128) NULL,
    source_url VARCHAR(768) NULL,
    verified TINYINT(1) NOT NULL DEFAULT 0,
    enabled TINYINT(1) NOT NULL DEFAULT 1,
    metadata JSON NULL,
    source_fetched_at DATETIME NULL,
    last_verified_at DATETIME NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_catalog_entity_game (entity_type, game_id),
    KEY ix_catalog_entity_name (entity_type, name),
    KEY ix_catalog_entity_category (entity_type, category, subcategory),
    CONSTRAINT fk_catalog_entity_source
        FOREIGN KEY (source_id) REFERENCES catalog_sources(id)
        ON DELETE SET NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS catalog_aliases (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    entity_id BIGINT UNSIGNED NOT NULL,
    alias VARCHAR(255) NOT NULL,
    normalized_alias VARCHAR(255) NOT NULL,
    alias_type ENUM('name','short','legacy','command','search','manual') NOT NULL DEFAULT 'search',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_catalog_alias (entity_id, normalized_alias),
    KEY ix_catalog_alias_lookup (normalized_alias),
    CONSTRAINT fk_catalog_alias_entity
        FOREIGN KEY (entity_id) REFERENCES catalog_entities(id)
        ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS catalog_relationships (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    from_entity_id BIGINT UNSIGNED NOT NULL,
    relation_type ENUM(
        'teaches','learned_by','requires','rewards','starts','ends','located_in',
        'belongs_to','variant_of','uses','grants','replaces','related'
    ) NOT NULL,
    to_entity_id BIGINT UNSIGNED NOT NULL,
    metadata JSON NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_catalog_relationship (from_entity_id, relation_type, to_entity_id),
    KEY ix_catalog_relationship_to (to_entity_id, relation_type),
    CONSTRAINT fk_catalog_relationship_from
        FOREIGN KEY (from_entity_id) REFERENCES catalog_entities(id)
        ON DELETE CASCADE,
    CONSTRAINT fk_catalog_relationship_to
        FOREIGN KEY (to_entity_id) REFERENCES catalog_entities(id)
        ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS catalog_training_profiles (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    profile_key VARCHAR(80) NOT NULL,
    display_name VARCHAR(160) NOT NULL,
    description TEXT NULL,
    class_id SMALLINT UNSIGNED NULL,
    min_level SMALLINT UNSIGNED NULL,
    max_level SMALLINT UNSIGNED NULL,
    enabled TINYINT(1) NOT NULL DEFAULT 1,
    metadata JSON NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_training_profile_key (profile_key)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS catalog_training_profile_entries (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    profile_id BIGINT UNSIGNED NOT NULL,
    spell_entity_id BIGINT UNSIGNED NOT NULL,
    sort_order INT NOT NULL DEFAULT 0,
    required_level SMALLINT UNSIGNED NULL,
    optional TINYINT(1) NOT NULL DEFAULT 0,
    notes VARCHAR(500) NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uq_training_profile_spell (profile_id, spell_entity_id),
    CONSTRAINT fk_training_entry_profile
        FOREIGN KEY (profile_id) REFERENCES catalog_training_profiles(id)
        ON DELETE CASCADE,
    CONSTRAINT fk_training_entry_spell
        FOREIGN KEY (spell_entity_id) REFERENCES catalog_entities(id)
        ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS catalog_sync_runs (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    source_id BIGINT UNSIGNED NULL,
    entity_type VARCHAR(32) NOT NULL,
    started_at DATETIME NOT NULL,
    finished_at DATETIME NULL,
    status ENUM('running','success','partial','failed') NOT NULL DEFAULT 'running',
    inserted_count INT UNSIGNED NOT NULL DEFAULT 0,
    updated_count INT UNSIGNED NOT NULL DEFAULT 0,
    skipped_count INT UNSIGNED NOT NULL DEFAULT 0,
    error_count INT UNSIGNED NOT NULL DEFAULT 0,
    message TEXT NULL,
    PRIMARY KEY (id),
    KEY ix_catalog_sync_runs_started (started_at),
    CONSTRAINT fk_catalog_sync_source
        FOREIGN KEY (source_id) REFERENCES catalog_sources(id)
        ON DELETE SET NULL
) ENGINE=InnoDB;

INSERT INTO catalog_sources
    (source_key, display_name, source_type, base_url, priority, notes)
VALUES
    ('azerothcore-world', 'AzerothCore world database', 'azerothcore', NULL, 10,
     'Server-compatible IDs and local item/world metadata.'),
    ('wotlk-client-dbc', 'Wrath 3.3.5 client DBC', 'dbc', NULL, 20,
     'Primary source for complete 3.3.5 spell, skill, area, faction, title and related client data.'),
    ('online-wotlk', 'Online WotLK metadata', 'online', NULL, 50,
     'Friendly descriptions and provenance captured locally; never required at button-click time.'),
    ('jmod-manual', 'JMod manual overrides', 'manual', NULL, 1,
     'Operator corrections and curated aliases take precedence over imported metadata.')
ON DUPLICATE KEY UPDATE
    display_name = VALUES(display_name),
    source_type = VALUES(source_type),
    priority = VALUES(priority),
    notes = VALUES(notes);
