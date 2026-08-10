# Roadmap

## Milestone 1: Repository and migration foundation

- [x] Create repository structure
- [x] Add architecture and command documentation
- [x] Add initial JMod database migration
- [ ] Import the existing admin web application from the current server deployment
- [ ] Import the existing privileged helper service
- [ ] Import JesterConsole addon source
- [ ] Add local development and deployment instructions

## Milestone 2: Shared command engine

- [ ] Central command registry
- [ ] `/jc help`
- [ ] `/jc info`
- [ ] `/jc players`
- [ ] `/jc announce`
- [ ] `/jc level`
- [ ] `/jc gold`
- [ ] Permission model and audit logging

## Milestone 3: Item intelligence

- [ ] Import `item_template` into JMod item catalog
- [ ] Search by item ID or name
- [ ] Alias support
- [ ] `/jc item`
- [ ] Web item browser
- [ ] Preset-friendly item resolution

## Milestone 4: Mounts, mounts, mounts

- [ ] Build mount catalog from AzerothCore / WotLK data
- [ ] Store mount spell ID, item ID when applicable, aliases, faction, and category
- [ ] `/jc mount search`
- [ ] `/jc mount give`
- [ ] Web mount library
- [ ] Riding training packages
- [ ] Rare and fun mount collections

## Milestone 5: Training

- [ ] Discover trainer tables and class/race requirements
- [ ] Riding training
- [ ] Class training packages
- [ ] Weapon skill packages
- [ ] Profession packages
- [ ] `/jc train`
- [ ] Web training panel

## Milestone 6: Presets and character provisioning

- [ ] Starter presets
- [ ] Level 30 adventure presets
- [ ] Level 60 classic presets
- [ ] Raid-ready presets
- [ ] Gear + gold + mounts + training bundles
- [ ] Dry-run preview before applying large presets

## Milestone 7: Character creation workflow

Admin-side raw character creation is intentionally not implemented until AzerothCore's character initialization path is reproduced safely. The first supported workflow should provision a character after normal client creation, then apply JMod presets.
