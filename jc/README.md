# JesterConsole

This directory owns the in-game `/jc` interface.

The live addon currently exists outside Git and should be copied into this repository before its protocol is changed. Until that import happens, this directory documents the intended contract instead of inventing replacement addon code.

## Design

JesterConsole should remain thin:

1. Parse or capture `/jc` input.
2. Send a structured request to JMod.
3. Render concise success/error output in game.

Command business logic belongs in shared JMod services so the web UI and addon behave the same way.

See `docs/jc-command-reference.md`.
