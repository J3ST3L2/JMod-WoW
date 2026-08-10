"""Shared JMod/JesterConsole command vocabulary.

This module is intentionally transport-agnostic.  The web admin, helper, and
JesterConsole addon can all use the same command names and semantics even
though the WoW 3.3.5a addon still transports GM commands through chat.
"""

from __future__ import annotations

from typing import Any


COMMANDS: dict[str, dict[str, Any]] = {
    "help": {
        "description": "Show available commands",
        "aliases": ["?"],
        "usage": "help",
        "target": "local",
    },
    "info": {
        "description": "Show server information",
        "aliases": [],
        "usage": "info",
        "target": "server",
    },
    "players": {
        "description": "List online players",
        "aliases": ["who"],
        "usage": "players",
        "target": "server",
    },
    "level": {
        "description": "Set character level",
        "aliases": ["lvl"],
        "usage": "level <character> <level>",
        "target": "character",
        "arguments": [
            {"name": "character", "type": "character"},
            {"name": "level", "type": "int", "min": 1, "max": 80},
        ],
    },
    "gold": {
        "description": "Set character gold",
        "aliases": ["money"],
        "usage": "gold <character> <gold>",
        "target": "character",
        "arguments": [
            {"name": "character", "type": "character"},
            {"name": "gold", "type": "int", "min": 0},
        ],
    },
    "mount": {
        "description": "Teach a mount spell",
        "aliases": ["learnmount"],
        "usage": "mount <character> <spell id>",
        "target": "character",
        "arguments": [
            {"name": "character", "type": "character"},
            {"name": "spell_id", "type": "spell"},
        ],
    },
    "train": {
        "description": "Teach a spell directly without a trainer",
        "aliases": ["training", "spell", "learn"],
        "usage": "train <character> <spell id>",
        "target": "character",
        "arguments": [
            {"name": "character", "type": "character"},
            {"name": "spell_id", "type": "spell"},
        ],
    },
    "teleport": {
        "description": "Fast travel a character to a named server teleport",
        "aliases": ["travel", "tele", "fasttravel"],
        "usage": "teleport <character> <location>",
        "target": "character",
        "arguments": [
            {"name": "character", "type": "character"},
            {"name": "location", "type": "teleport"},
        ],
    },
    "item": {
        "description": "Give item",
        "aliases": ["add"],
        "usage": "item <character> <item name|id> [count]",
        "target": "character",
        "arguments": [
            {"name": "character", "type": "character"},
            {"name": "item", "type": "item"},
            {"name": "count", "type": "int", "min": 1, "max": 1000, "default": 1},
        ],
    },
    "preset": {
        "description": "Apply character preset",
        "aliases": ["profile"],
        "usage": "preset <character> <preset>",
        "target": "character",
        "arguments": [
            {"name": "character", "type": "character"},
            {"name": "preset", "type": "preset"},
        ],
    },
}


# These mirror the aliases in the currently deployed JesterConsole 1.0.1.
# They live here now so the helper/web side has an explicit canonical copy to
# migrate toward instead of accumulating another unrelated alias table.
ITEM_ALIASES: dict[str, dict[str, Any]] = {
    "bags": {"id": 41600, "count": 4, "label": "4 Glacial Bags"},
    "bag": {"id": 41600, "count": 1, "label": "Glacial Bag"},
    "glacial bag": {"id": 41600, "count": 1, "label": "Glacial Bag"},
    "glacial bags": {"id": 41600, "count": 4, "label": "4 Glacial Bags"},
    "shadowmourne": {"id": 49623, "count": 1, "label": "Shadowmourne"},
    "benediction": {"id": 18608, "count": 1, "label": "Benediction"},
    "halo": {"id": 16921, "count": 1, "label": "Halo of Transcendence"},
    "neck": {"id": 18723, "count": 1, "label": "Animated Chain Necklace"},
    "shoulders": {"id": 16924, "count": 1, "label": "Pauldrons of Transcendence"},
    "cloak": {"id": 19870, "count": 1, "label": "Hakkari Loa Cloak"},
    "chest": {"id": 16923, "count": 1, "label": "Robes of Transcendence"},
    "wrists": {"id": 16926, "count": 1, "label": "Bindings of Transcendence"},
    "hands": {"id": 16920, "count": 1, "label": "Handguards of Transcendence"},
    "belt": {"id": 16925, "count": 1, "label": "Belt of Transcendence"},
    "legs": {"id": 16922, "count": 1, "label": "Leggings of Transcendence"},
    "boots": {"id": 16919, "count": 1, "label": "Boots of Transcendence"},
    "ring1": {"id": 19382, "count": 1, "label": "Pure Elementium Band"},
    "ring2": {"id": 19140, "count": 1, "label": "Cauterizing Band"},
    "trinket1": {"id": 19395, "count": 1, "label": "Rejuvenating Gem"},
    "trinket2": {"id": 17064, "count": 1, "label": "Shard of the Scale"},
    "wand": {"id": 19435, "count": 1, "label": "Essence Gatherer"},
}


COMMAND_ALIASES = {
    alias: name
    for name, spec in COMMANDS.items()
    for alias in spec.get("aliases", [])
}


def normalize_name(value: str) -> str:
    return " ".join((value or "").strip().lower().split())


def resolve_command(name: str) -> tuple[str | None, dict[str, Any] | None]:
    """Resolve a canonical command name and its specification."""
    normalized = normalize_name(name)
    canonical = normalized if normalized in COMMANDS else COMMAND_ALIASES.get(normalized)
    if canonical is None:
        return None, None
    return canonical, COMMANDS[canonical]


def resolve_item_alias(name: str) -> dict[str, Any] | None:
    """Return a copy of a known item alias, or None when it is unknown."""
    item = ITEM_ALIASES.get(normalize_name(name))
    return dict(item) if item else None


def help_lines() -> list[str]:
    """Render compact help text from the registry."""
    return [f"{name}: {spec['usage']} - {spec['description']}" for name, spec in COMMANDS.items()]
