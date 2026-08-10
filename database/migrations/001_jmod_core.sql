CREATE DATABASE IF NOT EXISTS jmod
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE jmod;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version VARCHAR(64) PRIMARY KEY,
    applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS settings (
    setting_key VARCHAR(128) PRIMARY KEY,
    setting_value JSON NOT NULL,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS audit_log (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    actor VARCHAR(128) NOT NULL,
    source ENUM('web','jc','api','system') NOT NULL,
    action VARCHAR(128) NOT NULL,
    target_type VARCHAR(64) NULL,
    target_id VARCHAR(128) NULL,
    request_payload JSON NULL,
    result_payload JSON NULL,
    success BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_audit_created_at (created_at),
    INDEX idx_audit_action (action),
    INDEX idx_audit_target (target_type, target_id)
);

CREATE TABLE IF NOT EXISTS character_state (
    character_guid INT UNSIGNED NOT NULL,
    state_key VARCHAR(128) NOT NULL,
    state_value JSON NOT NULL,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (character_guid, state_key)
);

CREATE TABLE IF NOT EXISTS item_catalog (
    item_id INT UNSIGNED PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    quality TINYINT UNSIGNED NULL,
    item_level INT UNSIGNED NULL,
    required_level INT UNSIGNED NULL,
    class_id INT NULL,
    subclass_id INT NULL,
    inventory_type INT NULL,
    source_table VARCHAR(64) NOT NULL DEFAULT 'item_template',
    refreshed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FULLTEXT KEY ft_item_name (name)
);

CREATE TABLE IF NOT EXISTS spell_catalog (
    spell_id INT UNSIGNED PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    category VARCHAR(64) NULL,
    source_table VARCHAR(64) NOT NULL DEFAULT 'spell_dbc',
    refreshed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FULLTEXT KEY ft_spell_name (name)
);

CREATE TABLE IF NOT EXISTS mount_catalog (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    spell_id INT UNSIGNED NOT NULL,
    item_id INT UNSIGNED NULL,
    name VARCHAR(255) NOT NULL,
    slug VARCHAR(255) NOT NULL,
    faction ENUM('alliance','horde','both','unknown') NOT NULL DEFAULT 'unknown',
    category VARCHAR(64) NULL,
    source VARCHAR(128) NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    metadata JSON NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_mount_spell (spell_id),
    UNIQUE KEY uq_mount_slug (slug),
    FULLTEXT KEY ft_mount_name (name)
);

CREATE TABLE IF NOT EXISTS aliases (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    alias_type ENUM('item','spell','mount','preset','command') NOT NULL,
    alias VARCHAR(128) NOT NULL,
    target_id VARCHAR(128) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_alias (alias_type, alias)
);

CREATE TABLE IF NOT EXISTS presets (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(128) NOT NULL,
    slug VARCHAR(128) NOT NULL,
    description TEXT NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_preset_slug (slug)
);

CREATE TABLE IF NOT EXISTS preset_actions (
    id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    preset_id BIGINT UNSIGNED NOT NULL,
    sequence_no INT UNSIGNED NOT NULL,
    action_type ENUM('level','gold','item','mount','spell','train','command','state') NOT NULL,
    payload JSON NOT NULL,
    required BOOLEAN NOT NULL DEFAULT TRUE,
    FOREIGN KEY (preset_id) REFERENCES presets(id) ON DELETE CASCADE,
    UNIQUE KEY uq_preset_sequence (preset_id, sequence_no)
);

INSERT IGNORE INTO schema_migrations(version) VALUES ('001_jmod_core');
