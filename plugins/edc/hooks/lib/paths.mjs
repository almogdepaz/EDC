// edc/hooks/lib/paths.mjs — single source of truth for the context dir
// layout, mirror of plugins/edc/scripts/edc-paths.sh.
//
// To make this configurable later (env var, manifest field, CLI flag)
// edit the defaults here AND in edc-paths.sh; everything else routes
// through these constants.

export const EDC_CONTEXT_DIR = "edc-context";
export const EDC_MANIFEST_REL = `${EDC_CONTEXT_DIR}/manifest.json`;
export const EDC_INDEX_REL = `${EDC_CONTEXT_DIR}/index.md`;
export const EDC_MODULES_DIR_REL = `${EDC_CONTEXT_DIR}/modules`;
export const EDC_REPORTS_DIR_REL = `${EDC_CONTEXT_DIR}/reports`;
