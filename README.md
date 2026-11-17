# Segue apps

The Segue consumer apps: macOS first, then Windows, phones later. The core
(engine, kernel, transports, FFI) lives in `raydocs/segue-core`; this repository
holds everything above it: `segue-client`, the app shells, privileged helpers,
the control plane, and their design documents.

- `docs/design/` — macOS, Windows, `segue-client`, `segue-cloud` MVP
- `docs/research/` — client and kill-switch studies, AI destination list sources
