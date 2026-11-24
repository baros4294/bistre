## Summary
- What changed and why.

## Verification
- [ ] `just check-all` passes locally (formatting, `bistre_guard`, Clippy, `cargo deny`, i18n, Flutter/Dart analysis, Rust & Dart tests).
- [ ] For UI changes: `just ui-gallery` run and PNGs inspected across desktop, phone, `200%` text, and RTL (`ar`).
- [ ] Affected docs (`docs/specs/*`, `docs/design/DESIGN.md`, `docs/adr/*`, `README.md`) updated in the same PR.
- [ ] No API keys, credentials, or user data included.
