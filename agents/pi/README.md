# EDC pi adapter implementation

The public pi-facing docs live at [`../../pi/README.md`](../../pi/README.md).

This directory contains the implementation used by the public `pi/` wrapper:

- `index.mjs` — EDC pi extension factory
- `install.sh` — underlying installer implementation

`pi/index.mjs` re-exports this adapter so pi users see a conventional root-level `pi/` package surface while existing implementation paths keep working.
