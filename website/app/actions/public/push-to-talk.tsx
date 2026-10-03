import { clientEntry, css, type Handle, on, ref } from 'remix/component'

import { approach, drawLight, type Light, speechLevel } from './light.ts'
import { NotesScreen } from './notes-screen.tsx'
import { bezel } from './styles.ts'

const PHRASES = [
  'Had a lovely weekend in Napa Valley with Johnny Appleseed, then drove up the coast to Mendocino for oysters and a very windy picnic.',
  'Remind me to send Johnny the photos from the vineyard and book the same cottage again for next spring.',
  'Can we push Friday’s design review to two o’clock and grab lunch at Caffè Macs afterwards?',
]

type Phase = 'idle' | 'rec' | 'proc' | 'paste'

const isTalkKey = (event: KeyboardEvent) => event.code === 'Space' || event.key === 'Fn'
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

// The interactive demo: hold on the screen (or hold space over it) to "dictate".
// ponytail: simulated voice level, no mic. Wire up getUserMedia if the demo should hear you.
export const PushToTalk = clientEntry(import.meta.url, function PushToTalk(handle: Handle) {
  let phase: Phase = 'idle'
  let committed = ''
  let pasting = ''
  let phraseIndex = 0
  let hovered = false
  let pressStart = 0
  let processStart = 0
  let timer: ReturnType<typeof setTimeout> | undefined
  const light: Light = { alpha: 0, height: 0, mix: 0, line: 0, level: 0 }

  function setPhase(next: Phase) {
    phase = next
    handle.update()
  }

  function start() {
    if (phase !== 'idle') return
    if (light.alpha < 0.05) light.mix = 0
    pressStart = performance.now()
    setPhase('rec')
  }

  function stop() {
    if (phase !== 'rec') return
    // A quick tap isn't a dictation.
    if (performance.now() - pressStart < 280) return setPhase('idle')
    processStart = performance.now()
    setPhase('proc')
    timer = setTimeout(paste, 1600)
  }

  async function paste() {
    const words = PHRASES[phraseIndex++ % PHRASES.length].split(' ')
    const base = committed ? `${committed} ` : ''
    phase = 'paste'
    for (let n = 1; n <= words.length; n++) {
      if (handle.signal.aborted) return
      pasting = base + words.slice(0, n).join(' ')
      await handle.update()
      await wait(28)
    }
    committed = pasting
    setPhase('idle')
  }

  function animate(root: HTMLElement, signal: AbortSignal) {
    const glow = root.querySelector('[data-part="glow"]') as HTMLCanvasElement
    const line = root.querySelector('[data-part="line"]') as HTMLCanvasElement
    let last = performance.now()

    let raf = requestAnimationFrame(function loop(ts) {
      const dt = Math.min(0.05, (ts - last) / 1000)
      last = ts
      const target = phase === 'rec' ? speechLevel((ts - pressStart) / 1000) : 0
      light.level = approach(light.level, target, target > light.level ? 22 : 7, dt)
      if (phase === 'rec') {
        light.alpha = approach(light.alpha, 1, 6, dt)
        light.height = approach(light.height, 0.09 + light.level * 0.16, 9, dt)
        light.mix = approach(light.mix, 0, 6, dt)
        light.line = approach(light.line, 0, 8, dt)
      } else if (phase === 'proc') {
        light.alpha = approach(light.alpha, 0.8, 3, dt)
        light.height = approach(light.height, 0.075, 3.2, dt)
        light.mix = approach(light.mix, 1, 3.2, dt)
        light.line = approach(light.line, ts - processStart > 280 ? 1 : 0, 4, dt)
      } else {
        light.alpha = approach(light.alpha, 0, 4.5, dt)
        light.height = approach(light.height, 0, 2.5, dt)
        light.line = approach(light.line, 0, 7, dt)
      }
      const cx = 0.5 + 0.32 * Math.sin(((ts - processStart) / 1000) * 1.8)
      drawLight(glow, line, light, ts / 1000, cx, { bar: 6, amp: 18 })
      raf = requestAnimationFrame(loop)
    })

    window.addEventListener(
      'keydown',
      (event) => {
        const focused = root.contains(document.activeElement)
        if (!(hovered || focused) || !isTalkKey(event)) return
        event.preventDefault()
        if (!event.repeat) start()
      },
      { signal },
    )
    // Only swallow keyup while recording, so space still activates buttons elsewhere.
    window.addEventListener(
      'keyup',
      (event) => {
        if (phase !== 'rec' || !isTalkKey(event)) return
        event.preventDefault()
        stop()
      },
      { signal },
    )
    signal.addEventListener('abort', () => {
      cancelAnimationFrame(raf)
      clearTimeout(timer)
    })
  }

  return () => (
    // biome-ignore lint/a11y/useSemanticElements: a press-and-hold surface around block content, which <button> can't contain
    <div
      role="button"
      tabIndex={0}
      aria-label="Hold to dictate"
      mix={[
        bezel,
        demoStyle,
        ref(animate),
        on('pointerdown', (event) => {
          if (event.button === 0) start()
        }),
        on('pointerup', stop),
        on('pointercancel', stop),
        on('pointerenter', () => {
          hovered = true
        }),
        on('pointerleave', () => {
          hovered = false
          stop()
        }),
        on('contextmenu', (event) => event.preventDefault()),
      ]}
    >
      <NotesScreen text={phase === 'paste' ? pasting : committed} blur="5.5cqw">
        <div
          aria-hidden="true"
          mix={hintStyle}
          style={{ opacity: phase !== 'idle' ? 0 : committed ? 0.55 : 1 }}
        >
          Hold <kbd mix={kbdStyle}>fn</kbd> or <kbd mix={kbdStyle}>space</kbd> to talk
        </div>
      </NotesScreen>
    </div>
  )
})

const demoStyle = css({
  width: 'min(1040px, 88vw)',
  aspectRatio: '16 / 10',
  margin: '0 auto',
  cursor: 'pointer',
  touchAction: 'none',
  userSelect: 'none',
  WebkitUserSelect: 'none',
  WebkitTouchCallout: 'none',
  outline: 'none',
  '&:focus-visible': { boxShadow: '0 0 0 2px var(--fg), 0 50px 120px rgba(0, 0, 0, 0.6)' },
})

const hintStyle = css({
  position: 'absolute',
  right: '20px',
  top: 'calc(2.6cqw + 16px)',
  display: 'flex',
  alignItems: 'center',
  gap: '6px',
  fontSize: '12px',
  color: '#6f6b67',
  transition: 'opacity 0.4s',
  pointerEvents: 'none',
})

const kbdStyle = css({
  font: 'inherit',
  padding: '1px 6px',
  borderRadius: '5px',
  border: '1px solid #3a3836',
  color: '#a39e98',
})
