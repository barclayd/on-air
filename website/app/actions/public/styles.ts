import { css } from 'remix/component'

export const headline = css({
  margin: 0,
  fontSize: 'clamp(40px, 5vw, 64px)',
  fontWeight: 700,
  letterSpacing: '-0.035em',
  lineHeight: 1,
})

export const lede = css({
  margin: 0,
  fontSize: 'clamp(17px, 1.6vw, 21px)',
  color: 'var(--muted)',
  textWrap: 'pretty',
})

/** The black bezel around a mock Mac screen. */
export const bezel = css({
  padding: '10px',
  background: '#050505',
  border: '1px solid #2b2927',
  borderRadius: '22px',
  boxShadow: '0 50px 120px rgba(0, 0, 0, 0.6)',
  boxSizing: 'border-box',
})
