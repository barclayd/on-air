import { css } from 'remix/component'

import { DOWNLOAD_URL, Document } from './document.tsx'
import { PushToTalk } from './public/push-to-talk.tsx'
import { ScrollStory } from './public/scroll-story.tsx'
import { bezel, headline, lede } from './public/styles.ts'

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
          <div mix={laptopStyle}>
            <div mix={[bezel, lidStyle]}>
              <PushToTalk />
            </div>
            <div aria-hidden="true" mix={baseStyle}>
              <div mix={baseShadowStyle} />
              <div mix={baseBodyStyle} />
              <div mix={baseNotchStyle} />
            </div>
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

const laptopStyle = css({
  width: 'min(1040px, 84vw)',
  margin: '28px auto 0',
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'center',
})

const lidStyle = css({
  width: '100%',
  aspectRatio: '16 / 10.4',
  padding: '10px 10px 0',
  borderBottom: 0,
  borderRadius: '22px 22px 0 0',
  display: 'flex',
  flexDirection: 'column',
})

const baseStyle = css({ position: 'relative', width: '106%', aspectRatio: '100 / 2.6' })

const baseShadowStyle = css({
  position: 'absolute',
  left: '4%',
  right: '4%',
  bottom: '-38%',
  height: '70%',
  borderRadius: '50%',
  background: 'rgba(0, 0, 0, 0.75)',
  filter: 'blur(10px)',
})

const baseBodyStyle = css({
  position: 'absolute',
  inset: 0,
  borderRadius: '3px 3px 2.2% 2.2% / 3px 3px 100% 100%',
  background: [
    // A highlight along the top edge, then shading rolling off each side.
    'linear-gradient(180deg, transparent 16%, rgba(255, 255, 255, 0.18) 16%, rgba(255, 255, 255, 0.18) calc(16% + 1px), transparent calc(16% + 1px))',
    'linear-gradient(90deg, rgba(0, 0, 0, 0.28), transparent 1.6%, transparent 98.4%, rgba(0, 0, 0, 0.28))',
    'linear-gradient(180deg, #c9c9cd 0%, #a3a3a8 9%, #86868b 16%, #7b7b80 45%, #69696e 78%, #4a4a4e 100%)',
  ].join(', '),
  boxShadow: 'inset 0 1px 0 rgba(255, 255, 255, 0.7), inset 0 -1px 1px rgba(0, 0, 0, 0.35)',
})

// The thumb scoop for opening the lid.
const baseNotchStyle = css({
  position: 'absolute',
  left: '50%',
  top: 0,
  width: '14.5%',
  height: '52%',
  transform: 'translateX(-50%)',
  borderRadius: '0 0 12px 12px / 0 0 70% 70%',
  background: 'linear-gradient(180deg, #5c5c61 0%, #7d7d82 55%, #8e8e93 100%)',
  boxShadow: 'inset 0 2px 3px rgba(0, 0, 0, 0.45), inset 0 -1px 0 rgba(255, 255, 255, 0.25)',
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
