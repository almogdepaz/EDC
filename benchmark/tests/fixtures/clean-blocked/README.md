# blocked-detection fixtures

Reconstructed, not captured: the 2026-11-06 enemy trial ran its shim in text
mode, so no raw stream-json from a blocked call exists yet. Event shapes follow
a real `claude -p --output-format stream-json --verbose` result event
(`type`, `is_error`, `stop_reason`, `result`); block texts are copied from the
trial `audit.log` files (CVE-2023-38545 api block, CVE-2018-0500 soft block).
Update these when a smoke run captures a real blocked call.
