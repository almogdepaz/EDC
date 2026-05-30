# Contributing

Thanks for improving EDC. Keep changes surgical and verify them before opening a PR.

## Development checks

```bash
npm test
npm run pack:check
```

`npm test` runs the shell/Node hardening suite. `npm run pack:check` verifies the public npm package contents.

## Repo conventions

- Do not edit generated `edc-context/` files as source changes.
- Keep public pi package contents controlled by `package.json` `files`.
- Keep hidden orchestrator prompt bundles under `plugins/edc/prompt-bundles/`; do not expose them as normal pi skills.
- Prefer npm-compatible scripts for release checks. Local development can still use bun to run package scripts.

## Release checklist

1. Update `package.json` version and `CHANGELOG.md`.
2. Run `npm run prepublishOnly`.
3. Publish with explicit public access:
   ```bash
   npm publish --access public
   ```
4. Smoke-install from npm in a temporary pi config directory.
5. Tag the release and push the branch/tag.
