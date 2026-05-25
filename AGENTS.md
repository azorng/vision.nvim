# AGENTS.md

## Intent

This plugin has one core job: attach the active Neovim visual selection to the
next supported agent prompt.

Keep the architecture small:

- Lua owns editor capture and the live local session.
- `visionctl` owns hook execution, provider adapters, rendering, and
  install-time config edits.
- Providers stay thin and must not know about Neovim capture details.

## Tests

Use the test wrapper:

```sh
./scripts/test
```

External e2e tests are explicit:

```sh
./scripts/test e2e
./scripts/test e2e codex
./scripts/test e2e claude
./scripts/test e2e cursor
./scripts/test e2e opencode
./scripts/test e2e pi
```
