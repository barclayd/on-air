import { css } from 'remix/component'

import { Document } from './document.tsx'
import { PushToTalk } from './public/push-to-talk.tsx'
import { ScrollStory } from './public/scroll-story.tsx'
import { headline, lede } from './public/styles.ts'

const DOWNLOAD_URL = 'https://github.com/barclayd/on-air/releases/latest'

const FEATURES = [
  { title: 'Free.', body: 'No subscription and no trial.' },
  { title: 'Every app.', body: 'Works in any text field on your Mac.' },
  {
    title: 'Just light.',
    body: 'No windows, menus or timers. A soft glow tells you it’s listening.',
  },
]

export function LandingPage() {
  return () => (
    <Document>
      <nav mix={navStyle}>
        <a href="/" mix={[linkStyle, css({ display: 'flex', alignItems: 'center', gap: '9px' })]}>
          <span mix={dotStyle} />
          On Air
        </a>
        <a
          href="#download"
          mix={[linkStyle, pillStyle, css({ padding: '6px 14px', fontSize: '13px' })]}
        >
          Download
        </a>
      </nav>

      <main>
        <ScrollStory />

        <section mix={css({ padding: '140px 24px 120px', textAlign: 'center' })}>
          <h2 mix={headline}>Try it.</h2>
          <p mix={[lede, css({ marginTop: '14px' })]}>
            Press and hold on the screen below, or hold space while your pointer is over it.
          </p>
          <div mix={css({ marginTop: '28px' })}>
            <PushToTalk />
          </div>
        </section>

        <section aria-label="Features" mix={featuresStyle}>
          {FEATURES.map(({ title, body }) => (
            <div key={title}>
              <h3
                mix={css({
                  margin: 0,
                  fontSize: '28px',
                  fontWeight: 700,
                  letterSpacing: '-0.02em',
                })}
              >
                {title}
              </h3>
              <p
                mix={css({
                  margin: '10px 0 0',
                  fontSize: '17px',
                  color: 'var(--muted)',
                  lineHeight: 1.45,
                })}
              >
                {body}
              </p>
            </div>
          ))}
        </section>

        <section id="download" mix={downloadStyle}>
          <h2
            mix={css({
              margin: 0,
              fontSize: 'clamp(56px, 8vw, 104px)',
              fontWeight: 700,
              letterSpacing: '-0.045em',
              lineHeight: 1,
            })}
          >
            On Air
          </h2>
          <p mix={[lede, css({ marginTop: '16px' })]}>Hold fn. Speak. Let go.</p>
          <a
            href={DOWNLOAD_URL}
            mix={[
              linkStyle,
              pillStyle,
              css({
                display: 'inline-block',
                marginTop: '36px',
                padding: '14px 28px',
                fontSize: '17px',
              }),
            ]}
          >
            Download for Mac
          </a>
        </section>
      </main>

      <footer mix={footerStyle}>On Air · Free for Mac</footer>
    </Document>
  )
}

const navStyle = css({
  position: 'fixed',
  inset: '0 0 auto',
  zIndex: 10,
  height: '52px',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  padding: '0 24px',
  background: 'rgba(11, 10, 10, 0.7)',
  backdropFilter: 'saturate(180%) blur(20px)',
  WebkitBackdropFilter: 'saturate(180%) blur(20px)',
  borderBottom: '1px solid rgba(255, 255, 255, 0.06)',
  fontSize: '15px',
  fontWeight: 600,
})

const linkStyle = css({ color: 'inherit', textDecoration: 'none' })

const dotStyle = css({
  width: '10px',
  height: '10px',
  borderRadius: '50%',
  background: 'var(--red)',
  boxShadow: '0 0 10px rgba(255, 74, 58, 0.8)',
  animation: 'dot-pulse 2.8s ease-in-out infinite',
  '@keyframes dot-pulse': {
    '0%, 100%': { boxShadow: '0 0 8px 0 rgba(255, 74, 58, 0.6)' },
    '50%': { boxShadow: '0 0 14px 2px rgba(255, 74, 58, 0.9)' },
  },
  '@media (prefers-reduced-motion: reduce)': { animation: 'none' },
})

const pillStyle = css({
  borderRadius: '999px',
  background: 'var(--fg)',
  color: 'var(--bg)',
  fontWeight: 600,
  transition: 'opacity 0.2s',
  '&:hover': { opacity: 0.85 },
})

const featuresStyle = css({
  display: 'grid',
  gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))',
  gap: '56px',
  width: 'min(1040px, 88vw)',
  margin: '0 auto',
  padding: '40px 0 0',
})

const downloadStyle = css({
  position: 'relative',
  overflow: 'hidden',
  padding: '160px 24px 180px',
  textAlign: 'center',
  '&::before': {
    content: '""',
    position: 'absolute',
    left: '50%',
    bottom: '-260px',
    width: '900px',
    height: '520px',
    transform: 'translateX(-50%)',
    background: 'radial-gradient(closest-side, rgba(255, 74, 58, 0.35), rgba(255, 74, 58, 0))',
    pointerEvents: 'none',
    zIndex: -1,
  },
  isolation: 'isolate',
})

const footerStyle = css({
  padding: '28px 24px',
  borderTop: '1px solid rgba(255, 255, 255, 0.06)',
  textAlign: 'center',
  fontSize: '13px',
  color: '#6f6b67',
})
