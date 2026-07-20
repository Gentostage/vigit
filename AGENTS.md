# Repository Guidelines

## Product Purpose

Vigit supports AI-assisted projects. It gives developers a fast,
keyboard-first way to review agent changes, move between affected files, make
corrections, and prepare precise feedback without losing project context. Keep
new features focused on this inspect-correct-comment loop.

## Project Structure & Module Organization

Vigit is a Lua Neovim plugin. Core behavior lives in `lua/vigit/`: `git.lua`
wraps Git commands, `parser.lua` parses status and diffs, `state.lua` owns view
state, and `ui.lua`, `changes_view.lua`, `highlights.lua`, and `actions.lua`
implement interaction and rendering. Keep public entry points in
`lua/vigit/init.lua`.

Tests live in `tests/*_spec.lua` and are loaded by `tests/run.lua`. Demo fixtures
and isolated Neovim configurations belong in `scripts/`. The project card is
plain HTML/CSS under `public/site/`; `app/`, `vite.config.js`, and
`scripts/prepare-sites-artifact.mjs` provide the Vinext hosting wrapper.

## Build, Test, and Development Commands

- `./scripts/demo.sh` opens a disposable Git fixture in clean Neovim.
- `./scripts/demo.sh --user-config` tests against your normal Neovim setup.
- `./scripts/demo.sh --plugins` enables the isolated Telescope integration.
- `lua tests/run.lua` runs the lightweight Lua specification suite.
- `npm install` installs website build dependencies.
- `npm run build` produces the deployable website in `dist/`.
- `npm audit` checks JavaScript dependencies for known vulnerabilities.

## Coding Style & Naming Conventions

Use two-space indentation in Lua, JavaScript, HTML, and CSS. Lua modules should
return an `M` table, keep helpers `local`, and use `snake_case` for filenames,
functions, and variables. Prefer small modules with explicit responsibilities;
keep Git shell construction inside `git.lua` and UI mutations inside UI/action
modules. Match existing CSS custom properties and semantic class names rather
than introducing one-off inline styles.

## Testing Guidelines

Add focused `it("describes behavior", function() ... end)` cases to the matching
`*_spec.lua` file. Mock `vim` APIs only at module boundaries and restore global
or `package.loaded` state after each case. There is no formal coverage target,
but parser, state, Git index operations, and keyboard workflows should receive
regression coverage. Run the Lua suite and manually exercise the relevant demo
mode before opening a PR.

## Commit & Pull Request Guidelines

Follow the established Conventional Commit style:
`fix(site): bundle worker runtime`, `docs: link project site`, or
`feat(ui): add side-by-side diff`. Keep subjects imperative and scoped.

PRs should explain the user-visible change, list validation commands, and link
related issues. Include terminal screenshots or a short recording for layout,
highlighting, tree, or key-mapping changes. Do not commit generated directories
such as `dist/`, `.wrangler/`, `.next/`, or `node_modules/`, nor local
`.codex/`, `.superpowers/`, or `docs/superpowers/` content.
