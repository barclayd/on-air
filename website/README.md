# On Air website

Landing page for On Air, built with Remix 3, TypeScript, Biome and Bun. It's separate from the macOS app.

## Commands

```sh
bun install
bun run dev        # http://localhost:44100, restarts on change
bun run start      # production mode, no build step
bun run test
bun run typecheck
bun run lint       # bun run format to fix
bun run build      # prerender into dist/
bun run preview    # build, then serve dist/ with wrangler dev on http://localhost:8787
bun run deploy     # build, then wrangler deploy
```

## Deploy

The site deploys to Cloudflare as a Worker that serves static assets only (`wrangler.jsonc`). `scripts/build.ts` renders `/` through the router and writes the HTML, every fingerprinted browser module, and `public/` into `dist/`. No server code runs on Cloudflare, so the page can't depend on the request.

`public/_headers` sets long-lived caching on `/assets/*`. It also serves `.ts`/`.tsx` modules as JavaScript, because Cloudflare would otherwise send them as `video/mp2t`.

## Layout

- `app/actions/landing-page.tsx` is the server-rendered page: nav, features, download and footer.
- `app/actions/document.tsx` is the HTML shell and colour tokens (`--bg`, `--fg`, `--muted`, `--red`).
- `app/actions/public/` holds the code that's hydrated in the browser:
  - `scroll-story.tsx` is the sticky, scroll-driven "Hold fn → Speak → Let go → Done" story.
  - `push-to-talk.tsx` is the "Try it." hold-to-talk demo.
  - `notes-screen.tsx` is the mock Notes screen both of them use.
  - `light.ts` is the canvas renderer for the red glow and blue processing line.
- `server.ts` serves `app/router.ts` with `Bun.serve`.
