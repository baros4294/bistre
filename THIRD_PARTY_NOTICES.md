# Third-Party Notices

Bistre is licensed under the MIT License (`LICENSE`). It bundles the following offline assets under permissive open-source licenses:

## Bundled Fonts (SIL Open Font License 1.1)
- **Inter** — Copyright © The Inter Project Authors (OFL-1.1)
- **JetBrains Mono** — Copyright © JetBrains s.r.o. (OFL-1.1)
- **Noto Sans Math** — Copyright © Google LLC (OFL-1.1)

All three faces are distributed as OFL-compliant subsets (glyph coverage in `docs/design/DESIGN.md` §3; checksums in `apps/bistre_app/assets/fonts/SHA256SUMS.txt`). The license text ships beside each font (`*-OFL.txt`) and the name tables retain the original copyright and license records; none of the fonts declares a Reserved Font Name.

## Pre-Compiled AI Lab Vector Icons (MIT License)
- **Lobe Icons (`@lobehub/icons-static-svg` v1.104.0)** — Copyright © LobeHub. Licensed under the MIT License. Compiled offline to binary `.vec` assets under `apps/bistre_app/assets/icons/labs/`. Brand trademarks belong to their respective owners.

## Embedded Offline BPE Tokenizer Vocabularies (MIT / Apache-2.0)
- **tiktoken (`tiktoken` v5.1.1)** — Pure-Rust BPE tokenizer engine (MIT OR Apache-2.0) with `ruzstd` (MIT).
- **OpenAI Vocabularies (`tiktoken-vocab-openai` v1.0.0)** — `o200k_base`, `o200k_harmony`, and `cl100k_base` (MIT).
- **Alibaba Qwen Vocabularies (`tiktoken-vocab-qwen` v1.0.0)** — `qwen2` and `qwen3_5` (Apache-2.0).
- **Zhipu GLM Vocabularies (`tiktoken-vocab-zhipu` v1.0.0)** — `glm4` and `glm5` (MIT).
