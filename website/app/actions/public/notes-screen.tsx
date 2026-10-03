import type { Handle, RemixNode } from 'remix/component'
import { css } from 'remix/component'

interface NotesScreenProps {
  /** Dictated text in the note, followed by a blinking caret. */
  text: string
  /** CSS blur radius for the glow canvas. */
  blur: string
  /** Overlays drawn above the light. */
  children?: RemixNode
}

// A mock Mac desktop with a Notes window. Everything is sized in container query
// units so the screen scales like a screenshot. The owning component finds the
// canvases by `data-part` and paints the light into them.
export function NotesScreen(handle: Handle<NotesScreenProps>) {
  return () => {
    const { text, blur, children } = handle.props

    return (
      <div mix={screenStyle}>
        <div mix={menuBarStyle}>
          <div mix={css({ display: 'flex', gap: '2cqw' })}>
            <span mix={css({ fontWeight: 600 })}>Notes</span>
            <span mix={dimStyle}>File</span>
            <span mix={dimStyle}>Edit</span>
            <span mix={dimStyle}>View</span>
          </div>
          <span mix={dimStyle}>Sat 3 Oct 09:41</span>
        </div>
        <div mix={windowStyle}>
          <div
            mix={css({
              height: '3.4cqw',
              display: 'flex',
              alignItems: 'center',
              gap: '0.7cqw',
              padding: '0 1.3cqw',
            })}
          >
            <span mix={trafficLightStyle} />
            <span mix={trafficLightStyle} />
            <span mix={trafficLightStyle} />
          </div>
          <div mix={noteStyle}>
            <div mix={css({ fontSize: '1.1cqw', color: '#8a8681' })}>3 October 2026 at 09:38</div>
            <div mix={css({ fontSize: '2.4cqw', fontWeight: 600, letterSpacing: '-0.01em' })}>
              Weekend notes
            </div>
            <div mix={css({ color: '#cfcbc6' })}>Highlights:</div>
            <div>
              {/* Own element: an empty text node isn't server-rendered, so it'd hydrate after the caret. */}
              <span>{text}</span>
              <span mix={caretStyle} />
            </div>
          </div>
        </div>
        <canvas data-part="glow" mix={canvasStyle} style={{ filter: `blur(${blur})` }} />
        <canvas data-part="line" mix={canvasStyle} />
        {children}
      </div>
    )
  }
}

const screenStyle = css({
  position: 'relative',
  width: '100%',
  height: '100%',
  borderRadius: '12px',
  overflow: 'hidden',
  background: '#1a1918',
  color: '#e9e6e2',
  textAlign: 'left',
  containerType: 'inline-size',
})

const menuBarStyle = css({
  position: 'absolute',
  inset: '0 0 auto',
  height: '2.6cqw',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  padding: '0 1.6cqw',
  background: 'rgba(30, 29, 28, 0.85)',
  borderBottom: '1px solid rgba(255, 255, 255, 0.05)',
  fontSize: '1.15cqw',
})

const dimStyle = css({ color: '#bdb9b4' })

const windowStyle = css({
  position: 'absolute',
  left: '18%',
  top: '15%',
  width: '64%',
  height: '66%',
  background: '#222120',
  border: '1px solid rgba(255, 255, 255, 0.07)',
  borderRadius: '1cqw',
  boxShadow: '0 3cqw 7cqw rgba(0, 0, 0, 0.5)',
  overflow: 'hidden',
})

const trafficLightStyle = css({
  width: '1cqw',
  height: '1cqw',
  borderRadius: '50%',
  background: '#3a3836',
})

const noteStyle = css({
  padding: '1cqw 4cqw',
  display: 'flex',
  flexDirection: 'column',
  gap: '1.3cqw',
  fontSize: '1.5cqw',
  lineHeight: 1.6,
  textWrap: 'pretty',
})

const caretStyle = css({
  display: 'inline-block',
  width: '2px',
  height: '1.1em',
  marginLeft: '1px',
  background: '#e9e6e2',
  verticalAlign: '-0.18em',
  animation: 'caret-blink 1.1s step-end infinite',
  '@keyframes caret-blink': {
    '0%, 49%': { opacity: 1 },
    '50%, 100%': { opacity: 0 },
  },
})

const canvasStyle = css({
  position: 'absolute',
  inset: 0,
  width: '100%',
  height: '100%',
  pointerEvents: 'none',
})
