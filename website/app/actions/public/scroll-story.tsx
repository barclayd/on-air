import { clientEntry, css, type Handle, on, ref } from 'remix/component'

import { approach, drawLight, speechLevel, tint } from './light.ts'
import { NotesScreen } from './notes-screen.tsx'
import { bezel, headline, lede } from './styles.ts'

// Each step owns a slice of the section's scroll progress (0–1).
const STEPS = [
  {
    tab: 'Hold fn',
    title: 'Hold fn.',
    body: 'From any app, in any text field.',
    range: [0.1, 0.28],
  },
  {
    tab: 'Speak',
    title: 'Speak.',
    body: 'A soft red light rises with your voice, so you always know you’re on air.',
    range: [0.28, 0.55],
  },
  {
    tab: 'Let go',
    title: 'Let go.',
    body: 'The light cools to a thin blue line while your words are transcribed.',
    range: [0.55, 0.72],
  },
  {
    tab: 'Done',
    title: 'Done.',
    body: 'Your text lands where you were typing, and the light is gone.',
    range: [0.72, 0.95],
  },
] as const

const WORDS =
  'Had a lovely weekend in Napa Valley with Johnny Appleseed, then drove up the coast to Mendocino for oysters and a very windy picnic.'.split(
    ' ',
  )

// A tall section with a sticky stage. Scrolling through it presses fn, speaks,
// releases and pastes, all driven from scroll position in one rAF loop.
export const ScrollStory = clientEntry(import.meta.url, function ScrollStory(handle: Handle) {
  let step = -1
  let words = 0
  let story: HTMLElement | undefined

  function scrollToStep(index: number) {
    if (!story) return
    const [a, b] = STEPS[index].range
    const target = index === 3 ? a + 0.14 : a + (b - a) * 0.6
    const top = story.getBoundingClientRect().top + window.scrollY
    window.scrollTo({
      top: top + target * (story.offsetHeight - window.innerHeight),
      behavior: 'smooth',
    })
  }

  function animate(root: HTMLElement, signal: AbortSignal) {
    story = root
    const part = <T extends HTMLElement = HTMLElement>(name: string) =>
      root.querySelector(`[data-part="${name}"]`) as T
    const hero = part('hero')
    const screen = part('screen')
    const spill = part('spill')
    const key = part('key')
    const keyTop = part('key-top')
    const keyGlow = part('key-glow')
    const keyLabel = part('key-label')
    const tabs = part('tabs')
    const glow = part<HTMLCanvasElement>('glow')
    const line = part<HTMLCanvasElement>('line')
    const captions = [...root.querySelectorAll<HTMLElement>('[data-part="caption"]')]

    let level = 0
    let last = 0
    let speaking = false
    let speakStart = 0
    let released = false
    let releaseStart = 0

    function frame(ts: number) {
      const dt = Math.min(0.05, (ts - last) / 1000)
      last = ts
      const t = ts / 1000
      const rect = root.getBoundingClientRect()
      const span = rect.height - window.innerHeight
      const p = span > 0 ? Math.max(0, Math.min(1, -rect.top / span)) : 0
      // Smoothstep of scroll progress across [a, b].
      const R = (a: number, b: number) => {
        const x = Math.max(0, Math.min(1, (p - a) / (b - a)))
        return x * x * (3 - 2 * x)
      }

      const intro = R(0, 0.1)
      hero.style.opacity = `${1 - R(0.005, 0.06)}`
      hero.style.transform = `translateY(${-intro * 40}px)`
      screen.style.transform = `translateY(${(1 - intro) * 10}vh) scale(${0.84 + 0.16 * intro})`
      tabs.style.opacity = `${R(0.07, 0.11)}`
      STEPS.forEach(({ range: [a, b] }, i) => {
        const o = R(a, a + 0.03) * (i === 3 ? 1 : 1 - R(b - 0.03, b))
        captions[i].style.opacity = `${o}`
        captions[i].style.transform = `translateY(${(1 - o) * 16}px)`
      })

      const keyDown = R(0.18, 0.2) * (1 - R(0.553, 0.562))
      key.style.opacity = `${R(0.1, 0.14) * (1 - R(0.6, 0.65))}`
      keyTop.style.transform = `translateY(${-6 + 6 * keyDown}px) scale(${1 - 0.03 * keyDown})`
      keyTop.style.boxShadow = `inset 0 1px 0 rgba(255,255,255,${0.08 - 0.05 * keyDown}),0 ${6 - 6 * keyDown}px 0 #0a0a0a,0 ${8 - 6 * keyDown}px ${14 - 10 * keyDown}px rgba(0,0,0,0.5)`
      keyTop.style.background = keyDown > 0.5 ? '#151516' : '#1d1d1f'
      keyGlow.style.opacity = `${keyDown * (0.75 + 0.25 * (0.5 + 0.5 * Math.sin(t * 1.7)))}`
      keyLabel.style.opacity = `${keyDown}`

      const nowSpeaking = p > 0.19 && p < 0.555
      if (nowSpeaking && !speaking) speakStart = t
      speaking = nowSpeaking
      const target = speaking ? speechLevel(t - speakStart) : 0
      level = approach(level, target, target > level ? 22 : 7, dt)

      const mix = R(0.555, 0.61)
      if (mix > 0 && !released) releaseStart = t
      released = mix > 0
      const alpha = R(0.19, 0.24) * (1 - 0.2 * mix) * (1 - R(0.72, 0.77))
      const recordingHeight = 0.09 + level * 0.16
      const cx = 0.5 + 0.32 * Math.sin((released ? t - releaseStart : 0) * 1.8)

      const [r, g, b] = tint(mix)
      spill.style.background = `radial-gradient(closest-side,rgba(${r},${g},${b},0.55),rgba(${r},${g},${b},0))`
      spill.style.opacity = `${alpha * (0.55 + 0.25 * (0.5 + 0.5 * Math.sin(t * 1.7)) + 0.3 * level) * (1 - 0.5 * mix)}`

      drawLight(
        glow,
        line,
        {
          alpha,
          height: recordingHeight + (0.075 - recordingHeight) * mix,
          mix,
          line: R(0.58, 0.63) * (1 - R(0.72, 0.76)),
          level,
        },
        t,
        cx,
        { bar: 4, amp: 12 },
      )

      const nextWords = p >= 0.86 ? WORDS.length : Math.floor(R(0.74, 0.86) * WORDS.length)
      const current = STEPS.findIndex(({ range: [a, b] }) => p >= a && p < b)
      const nextStep = p >= 0.95 ? 3 : current
      if (nextWords !== words || nextStep !== step) {
        words = nextWords
        step = nextStep
        handle.update()
      }
    }

    let raf = requestAnimationFrame(function loop(ts) {
      frame(ts)
      raf = requestAnimationFrame(loop)
    })
    signal.addEventListener('abort', () => cancelAnimationFrame(raf))
  }

  return () => (
    <section
      aria-label="How On Air works"
      mix={[css({ position: 'relative', height: '640vh' }), ref(animate)]}
    >
      <div mix={stageStyle}>
        <div data-part="hero" mix={heroStyle}>
          <h1
            mix={css({
              margin: 0,
              fontSize: 'clamp(64px, 10vw, 132px)',
              fontWeight: 700,
              letterSpacing: '-0.045em',
              lineHeight: 0.95,
            })}
          >
            On Air
          </h1>
          <p
            mix={css({
              margin: 0,
              fontSize: 'clamp(19px, 2vw, 26px)',
              color: 'var(--muted)',
              fontWeight: 500,
              letterSpacing: '-0.01em',
            })}
          >
            Push-to-talk dictation for Mac. Free.
          </p>
        </div>

        <div
          mix={css({
            position: 'relative',
            width: 'min(900px, 88vw)',
            height: '120px',
            flexShrink: 0,
          })}
        >
          {STEPS.map(({ title, body }) => (
            <div key={title} data-part="caption" mix={captionStyle}>
              <h2 mix={headline}>{title}</h2>
              <p mix={lede}>{body}</p>
            </div>
          ))}
        </div>

        <div data-part="screen" mix={screenStyle}>
          <div data-part="spill" mix={spillStyle} />
          <div mix={[bezel, css({ position: 'absolute', inset: 0, zIndex: 1 })]}>
            <NotesScreen text={WORDS.slice(0, words).join(' ')} blur="4cqw" />
          </div>
          <FnKey />
        </div>

        <div data-part="tabs" mix={tabsStyle}>
          {STEPS.map(({ tab }, i) => (
            <button
              key={tab}
              type="button"
              aria-current={step === i ? 'step' : undefined}
              mix={[tabStyle, on('click', () => scrollToStep(i))]}
            >
              {tab}
            </button>
          ))}
        </div>
      </div>
    </section>
  )
})

function FnKey() {
  return () => (
    <div data-part="key" aria-hidden="true" mix={keyStyle}>
      <div data-part="key-glow" mix={keyGlowStyle} />
      <div
        mix={css({
          position: 'relative',
          width: '100%',
          height: '100%',
          borderRadius: '16px',
          background: '#0c0c0c',
        })}
      >
        <div data-part="key-top" mix={keyTopStyle}>
          <span
            mix={css({
              position: 'absolute',
              right: '14px',
              top: '12px',
              fontSize: '21px',
              fontWeight: 500,
              color: '#f2f2f2',
              letterSpacing: '0.01em',
            })}
          >
            fn
          </span>
          <svg
            aria-hidden="true"
            width="24"
            height="24"
            viewBox="0 0 24 24"
            fill="none"
            stroke="#f2f2f2"
            stroke-width="1.4"
            mix={css({ position: 'absolute', left: '14px', bottom: '14px' })}
          >
            <circle cx="12" cy="12" r="9.5" />
            <ellipse cx="12" cy="12" rx="4.2" ry="9.5" />
            <line x1="12" y1="2.5" x2="12" y2="21.5" />
            <line x1="2.5" y1="12" x2="21.5" y2="12" />
            <path d="M4.2 7h15.6M4.2 17h15.6" />
          </svg>
        </div>
      </div>
      <div data-part="key-label" mix={keyLabelStyle}>
        <span
          mix={css({
            width: '7px',
            height: '7px',
            borderRadius: '50%',
            background: 'var(--red)',
            boxShadow: '0 0 8px rgba(255, 74, 58, 0.9)',
          })}
        />
        Holding
      </div>
    </div>
  )
}

const stageStyle = css({
  position: 'sticky',
  top: 0,
  height: '100vh',
  overflow: 'hidden',
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'center',
  justifyContent: 'center',
  gap: '26px',
  paddingTop: '30px',
  boxSizing: 'border-box',
})

const heroStyle = css({
  position: 'absolute',
  left: 0,
  right: 0,
  top: '15vh',
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'center',
  gap: '18px',
  textAlign: 'center',
  padding: '0 24px',
  zIndex: 3,
  pointerEvents: 'none',
})

const captionStyle = css({
  position: 'absolute',
  inset: 0,
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'center',
  justifyContent: 'flex-end',
  gap: '10px',
  textAlign: 'center',
  opacity: 0,
})

const screenStyle = css({
  position: 'relative',
  width: 'min(1040px, 86vw, calc((100vh - 290px) * 1.6))',
  aspectRatio: '16 / 10',
  flexShrink: 0,
  isolation: 'isolate',
  transform: 'translateY(10vh) scale(0.84)',
  willChange: 'transform',
})

const spillStyle = css({
  position: 'absolute',
  left: '-22%',
  right: '-22%',
  bottom: '-38%',
  height: '70%',
  borderRadius: '50%',
  filter: 'blur(40px)',
  opacity: 0,
  pointerEvents: 'none',
})

const keyStyle = css({
  position: 'absolute',
  right: '-40px',
  bottom: '14%',
  width: '124px',
  height: '124px',
  padding: '10px',
  boxSizing: 'border-box',
  borderRadius: '24px',
  background: '#d9d6d0',
  boxShadow: '0 24px 60px rgba(0, 0, 0, 0.55), inset 0 1px 0 rgba(255, 255, 255, 0.6)',
  opacity: 0,
  zIndex: 2,
  '@media (max-width: 640px)': {
    right: '-8px',
    transform: 'scale(0.6)',
    transformOrigin: 'bottom right',
  },
})

const keyGlowStyle = css({
  position: 'absolute',
  inset: '10px',
  borderRadius: '16px',
  boxShadow: '0 0 0 2px rgba(255, 74, 58, 0.9), 0 0 28px 6px rgba(255, 74, 58, 0.55)',
  opacity: 0,
  pointerEvents: 'none',
})

const keyTopStyle = css({
  position: 'absolute',
  inset: 0,
  borderRadius: '16px',
  background: '#1d1d1f',
  boxShadow:
    'inset 0 1px 0 rgba(255, 255, 255, 0.08), 0 6px 0 #0a0a0a, 0 8px 14px rgba(0, 0, 0, 0.5)',
  transform: 'translateY(-6px)',
})

const keyLabelStyle = css({
  position: 'absolute',
  left: '50%',
  bottom: '100%',
  marginBottom: '14px',
  transform: 'translateX(-50%)',
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
  whiteSpace: 'nowrap',
  fontSize: '13px',
  fontWeight: 500,
  opacity: 0,
})

const tabsStyle = css({
  // Above the screen's light spill, which would otherwise tint the tabs.
  position: 'relative',
  zIndex: 1,
  display: 'flex',
  gap: '6px',
  padding: '5px',
  borderRadius: '999px',
  background: 'rgba(255, 255, 255, 0.06)',
  border: '1px solid rgba(255, 255, 255, 0.06)',
  flexShrink: 0,
  opacity: 0,
})

const tabStyle = css({
  font: 'inherit',
  fontSize: '14px',
  fontWeight: 500,
  border: 0,
  borderRadius: '999px',
  padding: '8px 16px',
  cursor: 'pointer',
  background: 'transparent',
  color: 'var(--muted)',
  transition: 'background 0.3s, color 0.3s',
  '&[aria-current="step"]': { background: 'var(--fg)', color: 'var(--bg)' },
})
