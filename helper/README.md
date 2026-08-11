# Privileged Helper

The helper is JMod's privileged server-side execution service.

Responsibilities:

- validate operator requests
- execute supported AzerothCore worldserver commands
- perform narrowly scoped writes when a worldserver command is unsuitable
- expose item, mount, training, and preset operations to the web app
- expose the same operations to JesterConsole
- record state-changing actions in the JMod audit log

The current deployed helper should be migrated here from the live server before refactoring. Do not replace known-working worldserver attach/socket behavior with an untested transport during the first migration.
