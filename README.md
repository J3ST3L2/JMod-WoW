# JMod-WoW

JMod-WoW is the custom administration and in-game command platform for a private AzerothCore Wrath of the Lich King realm.

The project keeps JMod-specific state and automation separate from AzerothCore core databases while providing two operator interfaces:

- **Admin Web** for browsing and managing accounts, characters, gear, mounts, training, presets, server actions, and audit history.
- **JesterConsole (`/jc`)** for fast in-game administration and gameplay utilities.

## Goals

- Keep AzerothCore as the source of truth for game state.
- Store JMod custom state in a separate `jmod` database.
- Use one shared service layer for both the web UI and `/jc` commands.
- Prefer AzerothCore worldserver commands and supported game mechanisms over raw character-table edits.
- Index items, spells, mounts, trainers, and presets so operators do not need to memorize numeric IDs.
- Audit every state-changing action.
- Keep secrets out of Git.

## Repository layout

```text
admin/       Web administration application
helper/      Privileged host-side helper / GM API
jc/          JesterConsole addon and command protocol
jmod/        Shared command engine and domain services
database/    JMod migrations and seed data
tools/       Importers, discovery, and maintenance scripts
docs/        Architecture and operator documentation
deploy/      Docker/systemd examples and deployment helpers
```

## Current deployment target

The existing deployment runs on Ubuntu with AzerothCore services in Docker and a host-side privileged helper. This repository will absorb the existing `/opt/wow-admin` application and JesterConsole addon without storing credentials or player database dumps.

See `docs/architecture.md` and `docs/roadmap.md` for the implementation plan.
