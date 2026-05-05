# EDC Runtime Orientation

See `.context/index.md` for the architecture overview, module map, invariants, trust boundaries, and blast-radius summary.

See `.context/manifest.json` for the authoritative path-to-module routing contract, policy defaults, and report locations.

Installed runtime mode: **inject**. The harness auto-loads the matching `.context/modules/<name>.md` document before guarded operations when the active adapter supports injection.
