# Julia for Positron

Independent Julia extension repository for Positron IDE.

## What This Repo Contains

- TypeScript extension runtime and command wiring in `src/`
- Julia runtime package in `julia/Positron/`
- Local API typings in `typings/`
- Language config and branding assets

## Requirements

- Node.js 18+ (or newer LTS)
- npm 9+
- Julia 1.9+ (for Julia runtime tests)
- Positron IDE with `positron.positron-supervisor` available

## Quick Start

```bash
npm install
npm run compile
npm run package
```

This generates a `.vsix` that can be installed into Positron.

## End User Setup

For a new machine, users only need:

1. Install Julia
2. Install this extension (`.vsix`)
3. Start a Julia console session in Positron

On first session start, the extension automatically bootstraps required Julia
packages (`IJulia`, `JSON3`, `StructTypes`, and Positron.jl dependencies) and
LanguageServer dependencies. This can take a few minutes once, then subsequent
starts are faster.

## Testing

TypeScript compile check:

```bash
npm run compile
```

Julia runtime tests:

```bash
npm run test:julia
```

## Repository Layout

- `package.json`, `tsconfig.json`: standalone extension config
- `src/`: extension implementation (`extension.ts`, runtime/session/provider/LSP wiring)
- `julia/Positron/`: Positron Julia runtime package and tests
- `typings/`: extracted Positron and VS Code typings for standalone compilation
- `language-configuration/`: Julia language configuration JSON
- `resources/branding/`: Julia icon assets
- `scripts/languageserver/`: Julia LanguageServer bootstrap scripts

## Migration Notes

See `MIGRATION.md` for details on the extraction from Positron PR #11108.

## License

Elastic License 2.0. See `LICENSE`.
