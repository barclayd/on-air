import type { Handle, RemixNode } from 'remix/component'
import { css } from 'remix/component'
import { ImportMap } from 'remix/component/server'

import { scriptEntry } from '../assets.ts'

export const DOWNLOAD_URL = 'https://github.com/barclayd/on-air/releases/latest/download/On-Air.dmg'

const SITE_URL = 'https://useonair.app/'
const TITLE = 'On Air · Push-to-talk dictation for Mac'
const DESCRIPTION = 'Push-to-talk dictation for Mac. Hold fn, speak, let go. Free.'
const IMAGE_URL = `${SITE_URL}og.png`
const IMAGE_ALT =
  'On Air: a MacBook with fn held down and a red glow rising up the screen as you speak.'

const structuredData = {
  '@context': 'https://schema.org',
  '@type': 'SoftwareApplication',
  name: 'On Air',
  description: DESCRIPTION,
  url: SITE_URL,
  downloadUrl: DOWNLOAD_URL,
  image: IMAGE_URL,
  operatingSystem: 'macOS',
  applicationCategory: 'UtilitiesApplication',
  offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
}

export function Document(handle: Handle<{ children?: RemixNode }>) {
  return () => {
    const { href, importMap, preloads } = scriptEntry

    return (
      <html lang="en">
        <head>
          <meta charSet="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <meta name="color-scheme" content="dark" />
          <meta name="description" content={DESCRIPTION} />
          <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
          <link rel="canonical" href={SITE_URL} />
          <title>{TITLE}</title>
          {/* Slack, X and iMessage build link previews from these, not from JSON-LD. */}
          <meta property="og:type" content="website" />
          <meta property="og:site_name" content="On Air" />
          <meta property="og:title" content={TITLE} />
          <meta property="og:description" content={DESCRIPTION} />
          <meta property="og:url" content={SITE_URL} />
          <meta property="og:image" content={IMAGE_URL} />
          <meta property="og:image:width" content="1200" />
          <meta property="og:image:height" content="630" />
          <meta property="og:image:alt" content={IMAGE_ALT} />
          <meta name="twitter:card" content="summary_large_image" />
          <script type="application/ld+json">{JSON.stringify(structuredData)}</script>
          <ImportMap value={importMap} />
          {preloads.map((preloadHref) => (
            <link key={preloadHref} rel="modulepreload" href={preloadHref} />
          ))}
          <script type="module" src={href}></script>
        </head>
        <body mix={bodyStyle}>{handle.props.children}</body>
      </html>
    )
  }
}

const bodyStyle = css({
  '--bg': '#0b0a0a',
  '--fg': '#f2efeb',
  '--muted': '#a39e98',
  '--red': '#ff4a3a',
  margin: 0,
  background: 'var(--bg)',
  color: 'var(--fg)',
  fontFamily:
    "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', Helvetica, sans-serif",
  WebkitFontSmoothing: 'antialiased',
  MozOsxFontSmoothing: 'grayscale',
})
