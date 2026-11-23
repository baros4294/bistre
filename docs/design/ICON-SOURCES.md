# Iconography & Offline Vector Asset Sources

Bistre renders **100% of icons offline** as pre-compiled binary `.vec` files via Flutter's `vector_graphics` runtime — zero Material Icons, zero emojis as UI chrome, and **zero runtime external icon CDN requests or external references inside `crates/` or `apps/`**.

## 1. Bistre Editorial UI Icon Set (`apps/bistre_app/assets/icons/ui/*.vec`)
- **Authorship**: Original MIT-licensed custom 24×24 SVG icon set crafted specifically for Bistre (uniform `1.7px` rounded optical stroke weight, 57 glyphs covering navigation, editing, budgeting, updates, typography, theme controls, and the `info` mark used by the unavailable-cost popup). The `info` glyph (2026-11-23) is an original circle-and-stem drawing in the same stroke style, compiled with `dart run vector_graphics_compiler -i info.svg -o assets/icons/ui/info.vec`; its SVG source is not kept in the repository, matching the rest of the set.
- **Rendering**: Tinted dynamically via `EngravedIcon` (`ColorFilter.mode(color, BlendMode.srcIn)`).

## 2. Full-Color AI Lab & Provider Icon Pack (`apps/bistre_app/assets/icons/labs/*.vec`)
- **Upstream Source**: [`lobehub/lobe-icons`](https://github.com/lobehub/lobe-icons) — specifically the static SVG distribution [`@lobehub/icons-static-svg`](https://www.npmjs.com/package/@lobehub/icons-static-svg) (`v1.104.0`).
- **License**: **MIT License** (Copyright © LobeHub; full notice recorded in [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md)).
- **Coverage**: 42 bundled AI lab, model family, and inference provider vectors (`openai`, `anthropic`, `claude`, `google`, `gemini`, `deepseek`, `qwen`, `mistral`, `meta`, `ollama`, `openrouter`, `xai`, `grok`, `groq`, `cohere`, `perplexity`, `together`, `fireworks`, `huggingface`, `azure`, `azureai`, `bedrock`, `vertexai`, `moonshot`, `kimi`, `zhipu`, `nvidia`, `cloudflare`, `github`, `lmstudio`, `vllm`, `sambanova`, `cerebras`, `reka`, `yi`, `minimax`, `siliconcloud`, `vercel`, `deepinfra`, `novita`, `replicate`, `hyperbolic`).
  - Full-color `-color.svg` variants are used wherever published (30 labs).
  - Monochrome-native brands (`openai`, `anthropic`, `ollama`, `xai`, `grok`, `groq`, `moonshot`, `github`, `lmstudio`, `reka`, `vercel`, `replicate`) are tinted dynamically at runtime against `BistreThemeData.inkPrimary` so they remain crisp on both Day and Night canvases.
- **Custom User Icons**: End users may also attach any local `.png` or `.webp` image (or select any bundled lab slug) to a custom provider without touching app source code.

## 3. Offline Asset Refresh Procedure (Contributors Only)
1. Download the desired MIT-licensed static SVGs from `@lobehub/icons-static-svg` into a temporary directory outside the repository.
2. Normalize `width="1em"` / `height="1em"` → `width="24"` / `height="24"` and `currentColor` → `#000000`.
3. Compile each SVG into a compact `.vec` binary under `apps/bistre_app/assets/icons/labs/<slug>.vec`:
   ```bash
   cd apps/bistre_app
   dart run vector_graphics_compiler -i <staged.svg> -o assets/icons/labs/<slug>.vec
   ```
4. Never introduce external icon CDN URLs or upstream catalog identifiers into `crates/` or `apps/` (mechanically enforced by `just guard`).
