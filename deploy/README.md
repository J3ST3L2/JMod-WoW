# Deployment

Production deployment is intentionally documented separately from source code so credentials and host-specific details stay out of Git.

## Target shape

- AzerothCore auth/world/database services continue to run as their existing stack.
- JMod web runs as an unprivileged application service.
- JMod helper runs with only the privileges needed to reach the worldserver control path and scoped database credentials.
- The helper Unix socket lives in a persistent host path and is mounted into the web container.
- JMod custom state is stored in a separate `jmod` database.

## Migration rule

The first deployment should preserve the currently working transport and socket layout, then refactor in small verified steps. Do not combine repository migration, database migration, worldserver transport changes, and UI redesign into one deployment.

Host-specific values belong in `.env`, systemd environment files, or a secrets manager and must not be committed.
