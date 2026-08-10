# `/jc` Command Reference

JesterConsole is the fast in-game administration interface.

## Core

```text
/jc help
/jc info
/jc players
/jc announce <message>
```

## Character

```text
/jc level <character> <level>
/jc gold <character> <gold>
/jc rename <character>
/jc kick <character>
```

## Items

```text
/jc item search <text>
/jc item <character> <item name|item id> [count]
```

## Mounts

```text
/jc mount search <text>
/jc mount <character> <mount name|alias|spell id>
/jc mounts <character>
```

## Training

```text
/jc train <character> riding
/jc train <character> class
/jc train <character> profession <name>
```

## Presets

```text
/jc preset list
/jc preset preview <character> <preset>
/jc preset <character> <preset>
```

## Command behavior

- Names are case-insensitive at the JMod layer.
- Quoted arguments are supported for multi-word names.
- Human aliases are resolved through the JMod catalog.
- State-changing commands must produce an audit record.
- Large presets should support a preview/dry-run mode.
