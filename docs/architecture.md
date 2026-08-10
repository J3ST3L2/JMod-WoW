# Architecture

JMod-WoW is split into four logical layers so custom administration does not become tangled with AzerothCore internals.

## 1. AzerothCore

AzerothCore remains authoritative for normal game state: accounts, characters, world data, items, spells, quests, mail, and server execution.

JMod should prefer supported worldserver commands, mail delivery, and game-facing mechanisms over direct writes to AzerothCore tables. Direct writes are reserved for narrowly scoped cases that are understood and validated.

## 2. JMod database

The separate `jmod` database stores only JMod-owned state:

- command history and audit records
- item, spell, mount, and trainer indexes
- aliases used by `/jc`
- presets and preset actions
- character metadata and custom state
- server settings and feature flags

It must not duplicate authoritative character inventory, quest progress, or spell ownership unless the duplicated value is explicitly a cache.

## 3. Helper / GM API

The privileged helper is the only component allowed to perform sensitive server operations. It owns worldserver command execution and any narrowly scoped writes that require elevated database permissions.

The web app and JesterConsole should both use this same service layer. Business logic belongs in shared JMod services, not duplicated in UI code.

## 4. Operator interfaces

### Admin Web

The web interface provides account, character, server, gear, mount, training, preset, and audit workflows.

### JesterConsole

The WoW addon exposes `/jc` as the fast in-game operator interface. Commands should be human-friendly and resolve aliases rather than forcing numeric IDs.

Examples:

```text
/jc item Jestaj "Glacial Bag" 4
/jc mount Jestaj raven lord
/jc train Jestaj riding
/jc preset Jestaj priest60
```

## Safety rules

1. Never commit credentials, tokens, private keys, or player database dumps.
2. Audit every state-changing JMod action.
3. Validate character names and numeric parameters before execution.
4. Keep high-risk operations behind explicit permissions.
5. Prefer idempotent commands for presets and training packages.
6. Keep AzerothCore schema migrations out of JMod migrations.
7. Back up before any operation that changes large amounts of game state.
