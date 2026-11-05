# JMod Family Travel (AzerothCore WotLK 3.3.5a)

This is the **server-side** counterpart to `jc/JesterConsole/JesterFamily.lua`.

## Commands (available to normal players)

- `.jmodfamily go NAME`: ask a fellow party/raid member to let you teleport **to them**; the target must accept.
- `.jmodfamily summon NAME`: ask a fellow party/raid member to teleport **to you**; the target must accept.
- `.jmodfamily accept`: accept the pending request addressed to you.
- `.jmodfamily decline`: decline the pending request addressed to you.
- `.jmodfamily hub dalaran|shattrath|stormwind|orgrimmar`: travel to a predefined world DB teleport. Faction restrictions apply for Stormwind/Orgrimmar.
- Party invites use WoW's native `InviteUnit` API from the addon. They still require the invited player's acceptance, and obey AzerothCore party rules.

## Safety

- No GM access, hard-coded player whitelist, account changes, or database mutations.
- Travel requests expire after 60 seconds, are one-time, and have a 10-second request cooldown.
- Hub teleports have a 30-second cooldown.
- Only characters in the same normal party/raid are eligible for mutual travel.
- Blocked in combat, flight, transports/vehicles, battlegrounds, arenas, instances, while dead or already teleporting.
- Cleans up requests and cooldowns on player logout.
- Uses AzerothCore's existing `game_tele` rows. If a city name is absent, teleport is denied rather than using guessed coordinates.
- No automatic party join and no involuntary summon.

## Integration: candidate build only

The working core checkout on the user's WoW VM is
`/home/tberno/azerothcore-build-20261103`, pinned at `9d139488`.

From `tberno@wow`, run:

```bash
set -euo pipefail
BUILD="$HOME/azerothcore-build-20261103"
SRC="$(mktemp -d)"
git clone --depth 1 --branch feature/jmod-family-server \
  https://github.com/J3ST3L2/JMod-WoW.git "$SRC/repo"
test -d "$SRC/repo/server/modules/mod-jmod-family/src"
test ! -e "$BUILD/modules/mod-jmod-family"
cp -a "$SRC/repo/server/modules/mod-jmod-family" "$BUILD/modules/"
git -C "$BUILD" rev-parse --short HEAD
```

**Do not overwrite the existing tested worldserver image**.
Build a new tagged image after checking `mod-jmod-family` against the pinned
core's headers and CMake. This PR has not yet been compiled or tested on the VM.

To build a candidate without restarting live containers:

```bash
DOCKER_BUILDKIT=1 docker build --progress=plain \
  -f "$HOME/azerothcore-build-20261103/apps/docker/Dockerfile" \
  --target worldserver \
  -t jester-wow-worldserver:family-test \
  "$HOME/azerothcore-build-20261103"
```

Do not run database migrations, `docker compose up`, or switch production
images until the module compiles and a deployment/rollback plan is verified.
