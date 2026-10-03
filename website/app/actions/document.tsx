import type { Handle, RemixNode } from 'remix/component'
import { css } from 'remix/component'
import { ImportMap } from 'remix/component/server'

import { scriptEntry } from '../assets.ts'

export function Document(handle: Handle<{ children?: RemixNode }>) {
  return () => {
    const { href, importMap, preloads } = scriptEntry

    return (
      <html lang="en">
        <head>
          <meta charSet="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <meta name="color-scheme" content="dark" />
          <meta
            name="description"
            content="Push-to-talk dictation for Mac. Hold fn, speak, let go. Free."
          />
          <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
          <title>On Air — Push-to-talk dictation for Mac</title>
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
