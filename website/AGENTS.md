# on-air-website Agent Guide

The On Air landing page. It uses Remix 3 on Bun, with Biome for linting and formatting.

## Commands

```sh
bun install
bun run dev
bun run start
bun run test
bun run typecheck
bun run lint
bun run format
```

`bun run dev` uses `bun --watch` to restart the server on change. There's no HMR, so reload the browser yourself.

## Building Features

Read ./.agents/skills/remix/SKILL.md for the Remix mental model. It also explains how to find guides and API READMEs through `node_modules/remix/INDEX.md`.

## Layout

- `app/routes.ts` is the route contract, and `app/router.ts` wires it to `app/actions/controller.tsx`.
- `app/actions/landing-page.tsx` and `app/actions/document.tsx` are rendered only on the server.
- `app/actions/public/` is the only place browser code can live (see `allowFiles` in `app/assets.ts`). Interactive components there are `clientEntry` islands.
- Animated elements get their initial styles from `css()`. The rAF loops then write `el.style` directly, so they never fight a re-render.
- The root `public/` folder holds static files that are served unchanged.
