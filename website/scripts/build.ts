// Prerenders the site into dist/ for Cloudflare static assets (see wrangler.jsonc).
// Run with NODE_ENV=production so the asset server minifies and fingerprints.
import { cp, rm } from 'node:fs/promises'

import { router } from '../app/router.ts'

const outDir = 'dist'
// ponytail: finds browser modules by scanning for fingerprinted /assets/ URLs (name.@hash.ext).
// Swap for an asset manifest if Remix ships one, or if assets ever get referenced another way.
const fingerprinted = /\/assets\/[^"'`\s)]+\.@[\w-]+\.\w+/g

// Cloudflare 307s any path whose segments aren't encodeURIComponent-encoded, so write
// asset URLs the way it wants them (@ → %40) to save a redirect per module.
const canonical = (url: string) =>
  url
    .split('/')
    .map((part) => encodeURIComponent(decodeURIComponent(part)))
    .join('/')

await rm(outDir, { recursive: true, force: true })
await cp('public', outDir, { recursive: true })

const queue = ['/']
const seen = new Set(queue)

for (const pathname of queue) {
  const response = await router.fetch(new Request(new URL(pathname, 'http://localhost')))
  if (!response.ok) throw new Error(`GET ${pathname} returned ${response.status}`)

  const body = await response.text()
  const file = pathname === '/' ? '/index.html' : decodeURIComponent(pathname)
  await Bun.write(`${outDir}${file}`, body.replace(fingerprinted, canonical))

  for (const url of body.match(fingerprinted) ?? []) {
    if (!seen.has(url)) {
      seen.add(url)
      queue.push(url)
    }
  }
}

console.log(`Wrote ${queue.length} files to ${outDir}/`)
