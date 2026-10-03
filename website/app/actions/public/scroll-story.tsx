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
    const deckGlow = part('deck-glow')
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
      keyTop.style.transform = `translateY(${0.22 * keyDown}cqw) scale(${1 - 0.04 * keyDown})`
      keyTop.style.boxShadow = `inset 0 0.08cqw 0 rgba(255,255,255,${0.07 - 0.05 * keyDown}),0 ${0.18 * (1 - keyDown)}cqw 0 #050506`
      keyTop.style.background = keyDown > 0.5 ? '#060607' : '#0c0c0d'
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
      deckGlow.style.background = `linear-gradient(180deg,rgba(${r},${g},${b},0.45),rgba(${r},${g},${b},0.12) 30%,rgba(${r},${g},${b},0) 60%)`
      deckGlow.style.opacity = `${alpha * (0.6 + 0.2 * (0.5 + 0.5 * Math.sin(t * 1.7)) + 0.3 * level) * (1 - 0.5 * mix)}`

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
            height: 'clamp(76px, 13vh, 120px)',
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

        <div data-part="screen" mix={laptopStyle}>
          <div mix={css({ position: 'relative', width: '100%', aspectRatio: '16 / 10' })}>
            <div data-part="spill" mix={spillStyle} />
            <div mix={[bezel, lidStyle]}>
              <NotesScreen text={WORDS.slice(0, words).join(' ')} blur="4cqw" />
            </div>
          </div>
          <div mix={hingeStyle} />
          <Deck />
        </div>

        {/* Above the screen's light spill, which would otherwise tint the tabs. */}
        <div mix={css({ position: 'relative', zIndex: 1, flexShrink: 0 })}>
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
            Holding fn
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
      </div>
    </section>
  )
})

interface Key {
  label: string
  /** Shifted symbol or glyph, drawn above the label. */
  top: string
  grow: number
  justify: string
  align: string
  size: string
}

const key = (
  label: string,
  { top = '', grow = 1, justify = 'center', align = 'center', size = '1.5cqw' } = {},
): Key => ({ label, top, grow, justify, align, size })
const mod = (label: string, top: string, grow: number, right = false) =>
  key(label, {
    top,
    grow,
    justify: 'space-between',
    align: right ? 'flex-end' : 'flex-start',
    size: '0.95cqw',
  })
const sym = (label: string, top: string) => key(label, { top, size: '1.1cqw' })
const letters = (row: string) => [...row].map((c) => key(c))

// A MacBook keyboard. 'fn' and 'arrows' are drawn specially.
const ROWS: { height: string; keys: (Key | 'fn' | 'arrows')[] }[] = [
  {
    height: '2.9cqw',
    keys: [
      key('esc', { grow: 1.5, justify: 'flex-end', align: 'flex-start', size: '0.85cqw' }),
      ...Array.from({ length: 12 }, (_, i) => key(`F${i + 1}`, { size: '0.75cqw' })),
      key(''),
    ],
  },
  {
    height: '5.3cqw',
    keys: [
      sym('`', '~'),
      ...[...'1!2@3#4$5%6^7&8*9(0)-_=+'.matchAll(/../g)].map(([p]) => sym(p[0], p[1])),
      mod('delete', '', 1.5, true),
    ],
  },
  {
    height: '5.3cqw',
    keys: [
      mod('tab', '⇥', 1.5),
      ...letters('QWERTYUIOP'),
      sym('[', '{'),
      sym(']', '}'),
      sym('\\', '|'),
    ],
  },
  {
    height: '5.3cqw',
    keys: [
      mod('caps lock', '•', 1.8),
      ...letters('ASDFGHJKL'),
      sym(';', ':'),
      sym("'", '"'),
      mod('return', '↩', 1.8, true),
    ],
  },
  {
    height: '5.3cqw',
    keys: [
      mod('shift', '⇧', 2.3),
      ...letters('ZXCVBNM'),
      sym(',', '<'),
      sym('.', '>'),
      sym('/', '?'),
      mod('shift', '⇧', 2.3, true),
    ],
  },
  {
    height: '5.3cqw',
    keys: [
      'fn',
      mod('control', '⌃', 1),
      mod('option', '⌥', 1),
      mod('command', '⌘', 1.25),
      key('', { grow: 5 }),
      mod('command', '⌘', 1.25, true),
      mod('option', '⌥', 1, true),
      'arrows',
    ],
  },
]

// The keyboard half of the laptop, tilted back in 3D. Sized in container query
// units so it scales with the screen.
function Deck() {
  return () => (
    <div aria-hidden="true" mix={deckWrapStyle}>
      <div mix={deckStyle}>
        <div mix={keyboardStyle}>
          {ROWS.map(({ height, keys }, row) => (
            <div key={row} mix={rowStyle} style={{ height }}>
              {keys.map((k, i) =>
                k === 'fn' ? (
                  fnKey()
                ) : k === 'arrows' ? (
                  arrows()
                ) : (
                  <div
                    key={i}
                    mix={[keyCap, labelledKeyStyle]}
                    style={{
                      flex: `${k.grow} 1 0`,
                      justifyContent: k.justify,
                      alignItems: k.align,
                      fontSize: k.size,
                    }}
                  >
                    <span>{k.top}</span>
                    <span>{k.label}</span>
                  </div>
                ),
              )}
            </div>
          ))}
        </div>
        <div mix={trackpadStyle} />
        <div data-part="deck-glow" mix={deckGlowStyle} />
        <div mix={thumbScoopStyle} />
      </div>
    </div>
  )
}

function fnKey() {
  return (
    <div key="fn" mix={css({ flex: '1 1 0', minWidth: 0, position: 'relative' })}>
      <div data-part="key-glow" mix={keyGlowStyle} />
      <div data-part="key-top" mix={[keyCap, css({ position: 'absolute', inset: 0 })]}>
        <span
          mix={css({ position: 'absolute', right: '0.6cqw', top: '0.4cqw', fontSize: '1.05cqw' })}
        >
          fn
        </span>
        <svg
          aria-hidden="true"
          viewBox="0 0 24 24"
          fill="none"
          stroke="#cfcfd2"
          stroke-width="1.6"
          mix={css({
            position: 'absolute',
            left: '0.6cqw',
            bottom: '0.5cqw',
            width: '1.5cqw',
            height: '1.5cqw',
          })}
        >
          <circle cx="12" cy="12" r="9.5" />
          <ellipse cx="12" cy="12" rx="4.2" ry="9.5" />
          <line x1="2.5" y1="12" x2="21.5" y2="12" />
          <path d="M4.2 7h15.6M4.2 17h15.6" />
        </svg>
      </div>
    </div>
  )
}

function arrows() {
  return (
    <div
      key="arrows"
      mix={css({
        flex: '3 1 0',
        minWidth: 0,
        display: 'flex',
        gap: '0.45cqw',
        alignItems: 'flex-end',
        fontSize: '0.8cqw',
      })}
    >
      <div mix={[keyCap, arrowStyle]} style={{ height: '48%' }}>
        ◀
      </div>
      <div
        mix={css({
          flex: '1 1 0',
          height: '100%',
          display: 'flex',
          flexDirection: 'column',
          gap: '0.3cqw',
        })}
      >
        <div mix={[keyCap, arrowStyle]}>▲</div>
        <div mix={[keyCap, arrowStyle]}>▼</div>
      </div>
      <div mix={[keyCap, arrowStyle]} style={{ height: '48%' }}>
        ▶
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
  gap: 'clamp(10px, 2vh, 26px)',
  paddingTop: '52px',
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

const laptopStyle = css({
  position: 'relative',
  width: 'min(1040px, 82vw, calc(80vh - 100px))',
  flexShrink: 0,
  isolation: 'isolate',
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'center',
  transform: 'translateY(10vh) scale(0.84)',
  transformOrigin: '50% 40%',
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

const lidStyle = css({
  position: 'absolute',
  inset: 0,
  zIndex: 1,
  borderRadius: '22px 22px 6px 6px',
})

const hingeStyle = css({
  position: 'relative',
  zIndex: 2,
  width: '96%',
  aspectRatio: '100 / 1.2',
  marginTop: '-1px',
  borderRadius: '0 0 5px 5px',
  background: 'linear-gradient(180deg, #0c0c0e 0%, #2c2c2f 55%, #1a1a1c 100%)',
})

const deckWrapStyle = css({
  position: 'relative',
  zIndex: 1,
  width: '100%',
  aspectRatio: '1 / 0.37',
  perspective: '5000px',
  perspectiveOrigin: '50% 0%',
  // Here rather than on the deck, so the deck's own shadow can use cqw too.
  containerType: 'inline-size',
})

const deckStyle = css({
  position: 'absolute',
  left: 0,
  top: 0,
  width: '100%',
  aspectRatio: '1.45 / 1',
  transformOrigin: '50% 0',
  transform: 'rotateX(64deg)',
  borderRadius: '8px 8px 26px 26px',
  background: 'linear-gradient(180deg, #4a4a4e 0%, #3d3d41 35%, #333337 100%)',
  // The last two shadows are the front edge: a copy of the deck's outline pushed
  // down, so the thickness wraps the rounded corners exactly.
  boxShadow:
    'inset 0 2px 0 rgba(255, 255, 255, 0.12), inset 0 -4px 10px rgba(0, 0, 0, 0.35), 0 0.3cqw 0 #2c2c2f, 0 1.4cqw 0 #161618',
})

const keyboardStyle = css({
  position: 'absolute',
  left: '7cqw',
  right: '7cqw',
  top: '4.5cqw',
  padding: '0.5cqw',
  borderRadius: '1cqw',
  background: '#161618',
  boxShadow: 'inset 0 0.15cqw 0.5cqw rgba(0, 0, 0, 0.7)',
  display: 'flex',
  flexDirection: 'column',
  gap: '0.45cqw',
})

const rowStyle = css({ display: 'flex', gap: '0.45cqw' })

const keyCap = css({
  borderRadius: '0.55cqw',
  background: '#0c0c0d',
  boxShadow: 'inset 0 0.08cqw 0 rgba(255, 255, 255, 0.07), 0 0.18cqw 0 #050506',
  boxSizing: 'border-box',
  color: '#cfcfd2',
})

const labelledKeyStyle = css({
  minWidth: 0,
  display: 'flex',
  flexDirection: 'column',
  padding: '0.4cqw 0.6cqw',
  lineHeight: 1.15,
})

const arrowStyle = css({
  flex: '1 1 0',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
})

const keyGlowStyle = css({
  position: 'absolute',
  inset: 0,
  borderRadius: '0.55cqw',
  boxShadow: '0 0 0 0.25cqw rgba(255, 80, 62, 0.95), 0 0 3cqw 0.8cqw rgba(255, 74, 58, 0.6)',
  opacity: 0,
  pointerEvents: 'none',
})

const trackpadStyle = css({
  position: 'absolute',
  left: '27cqw',
  top: '41cqw',
  width: '46cqw',
  height: '25cqw',
  borderRadius: '1.6cqw',
  background: 'linear-gradient(180deg, #404044, #38383c)',
  boxShadow: 'inset 0 0 0 0.12cqw rgba(0, 0, 0, 0.35), inset 0 0.15cqw 0 rgba(255, 255, 255, 0.06)',
})

// The light spilling down onto the keyboard.
const deckGlowStyle = css({
  position: 'absolute',
  inset: 0,
  borderRadius: 'inherit',
  mixBlendMode: 'screen',
  opacity: 0,
  pointerEvents: 'none',
})

// Notched into the top of the front edge.
const thumbScoopStyle = css({
  position: 'absolute',
  left: '43cqw',
  width: '14cqw',
  top: '100%',
  height: '0.7cqw',
  borderRadius: '0 0 1cqw 1cqw',
  background: '#0d0d0e',
})

const keyLabelStyle = css({
  position: 'absolute',
  right: '100%',
  top: '50%',
  marginRight: '16px',
  transform: 'translateY(-50%)',
  display: 'flex',
  alignItems: 'center',
  gap: '8px',
  whiteSpace: 'nowrap',
  fontSize: '13px',
  fontWeight: 500,
  opacity: 0,
  // No room beside the tabs on a phone; the glowing key says it anyway.
  '@media (max-width: 640px)': { display: 'none' },
})

const tabsStyle = css({
  display: 'flex',
  gap: '6px',
  padding: '5px',
  borderRadius: '999px',
  background: 'rgba(255, 255, 255, 0.06)',
  border: '1px solid rgba(255, 255, 255, 0.06)',
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
