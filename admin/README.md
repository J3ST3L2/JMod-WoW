# Admin Web

This directory will contain the migrated JMod administration web application.

Planned modules:

- dashboard
- accounts
- characters
- gear and item search
- mounts
- training
- presets
- server controls
- audit log

The existing production admin application should be imported here rather than rewritten from memory. Once imported, routes should call shared JMod services or the privileged helper instead of duplicating game logic in templates/controllers.
