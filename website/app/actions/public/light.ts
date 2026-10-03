// The On Air light: a red bloom that rises with your voice, cooling to a thin
// blue line while words are transcribed. Shared by the scroll story and the demo.

type Rgb = [number, number, number]

export interface Light {
  /** Overall glow opacity, 0–1. */
  alpha: number
  /** Glow height as a fraction of the canvas. */
  height: number
  /** 0 = recording (red), 1 = processing (blue). */
  mix: number
  /** Opacity of the blue processing line. */
  line: number
  /** Voice level, 0–1. */
  level: number
}

function blend(a: Rgb, b: Rgb, m: number): Rgb {
  return [0, 1, 2].map((i) => Math.round(a[i] + (b[i] - a[i]) * m)) as Rgb
}

/** The light's core colour: red while recording, blue while processing. */
export function tint(mix: number) {
  return blend([240, 40, 34], [70, 140, 255], mix)
}

/** Fake speech envelope for `t` seconds into a recording. */
export function speechLevel(t: number) {
  const syllable = Math.max(0, Math.sin(t * 8.5 + 2 * Math.sin(t * 1.7))) ** 0.6
  const talking = Math.sin(t * 0.8 + 1.2) > -0.6 ? 1 : 0.08
  const dynamics = 0.55 + 0.45 * Math.sin(t * 1.9 + Math.sin(t * 0.7) * 3)
  return Math.min(
    1,
    (syllable * talking * dynamics * 0.9 + Math.random() * 0.05) * Math.min(1, t / 0.35),
  )
}

/** Eases `value` toward `target`, framerate-independent. */
export function approach(value: number, target: number, rate: number, dt: number) {
  return value + (target - value) * (1 - Math.exp(-dt * rate))
}

function fit(canvas: HTMLCanvasElement, scale: number) {
  const width = Math.max(1, Math.round(canvas.clientWidth * scale))
  const height = Math.max(1, Math.round(canvas.clientHeight * scale))
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width
    canvas.height = height
  }
}

/**
 * Paints one frame. `cx` is the 0–1 position of the processing shimmer, `bar` the
 * height of the hot edge along the bottom and `amp` the processing line's wave height.
 */
export function drawLight(
  glowCanvas: HTMLCanvasElement,
  lineCanvas: HTMLCanvasElement,
  light: Light,
  t: number,
  cx: number,
  { bar, amp }: { bar: number; amp: number },
) {
  const dpr = Math.min(window.devicePixelRatio || 1, 2)
  // The glow is blurred in CSS, so half resolution is plenty.
  fit(glowCanvas, 0.5)
  fit(lineCanvas, dpr)

  const { alpha, height, mix, line, level } = light
  const ctx = glowCanvas.getContext('2d')
  const lc = lineCanvas.getContext('2d')
  if (!ctx || !lc) return

  const W = glowCanvas.width
  const H = glowCanvas.height
  ctx.clearRect(0, 0, W, H)

  if (alpha > 0.003) {
    const [cr, cg, cb] = tint(mix)
    const [wr, wg, wb] = blend([255, 104, 72], [130, 180, 255], mix)
    const pulse = 0.5 + 0.5 * Math.sin(t * 1.7)
    const h = height * H * (0.94 + 0.08 * pulse * (1 - mix))
    const a = alpha * (0.7 + 0.3 * pulse * (1 - 0.6 * mix)) * (0.8 + 0.2 * level)

    const spill = ctx.createLinearGradient(0, H, 0, H * 0.35)
    spill.addColorStop(0, `rgba(${cr},${cg},${cb},${0.14 * a})`)
    spill.addColorStop(1, `rgba(${cr},${cg},${cb},0)`)
    ctx.fillStyle = spill
    ctx.fillRect(0, H * 0.35, W, H * 0.65)

    ctx.beginPath()
    ctx.moveTo(0, H)
    for (let i = 0; i <= 48; i++) {
      const u = i / 48
      const hump = Math.exp(-((u - 0.5) ** 2) / 0.09)
      const wave = Math.sin(u * 6 + t * 1.3) * 0.6 + Math.sin(u * 11 - t * 2.1) * 0.4
      const recording = h * (0.55 + 0.45 * hump) + h * 0.16 * (0.3 + level) * wave
      const processing = h * (0.6 + 0.9 * Math.exp(-(((u - cx) / 0.2) ** 2)))
      ctx.lineTo(u * W, H - (recording * (1 - mix) + processing * mix))
    }
    ctx.lineTo(W, H)
    ctx.closePath()

    const body = ctx.createLinearGradient(0, H, 0, H - h * 2.2)
    body.addColorStop(0, `rgba(${wr},${wg},${wb},${0.7 * a})`)
    body.addColorStop(0.3, `rgba(${cr},${cg},${cb},${0.42 * a})`)
    body.addColorStop(0.7, `rgba(${cr},${cg},${cb},${0.12 * a})`)
    body.addColorStop(1, `rgba(${cr},${cg},${cb},0)`)
    ctx.fillStyle = body
    ctx.fill()

    ctx.fillStyle = `rgba(${wr},${wg},${wb},${0.6 * a * (0.55 + 0.45 * level * (1 - mix) + 0.2 * mix)})`
    ctx.fillRect(0, H - bar, W, bar)
  }

  const LW = lineCanvas.width
  const LH = lineCanvas.height
  lc.clearRect(0, 0, LW, LH)
  if (line <= 0.01) return

  const y0 = LH * 0.955
  const k = 0.03 / dpr
  const centre = cx * LW
  const spread = 0.16 * LW
  const clamp = (v: number) => Math.max(0, Math.min(1, v))
  const dim = `rgba(190,215,255,${0.12 * line})`
  const stroke = lc.createLinearGradient(0, 0, LW, 0)
  stroke.addColorStop(0, dim)
  stroke.addColorStop(clamp(cx - 0.28), dim)
  stroke.addColorStop(clamp(cx), `rgba(225,238,255,${0.95 * line})`)
  stroke.addColorStop(clamp(cx + 0.28), dim)
  stroke.addColorStop(1, dim)

  lc.beginPath()
  for (let x = 0; x <= LW; x += 2 * dpr) {
    const envelope = Math.exp(-(((x - centre) / spread) ** 2))
    const y =
      y0 +
      envelope * amp * dpr * (Math.sin(x * k - t * 9) * 0.7 + Math.sin(x * k * 1.7 - t * 12) * 0.3)
    if (x === 0) lc.moveTo(x, y)
    else lc.lineTo(x, y)
  }
  lc.strokeStyle = stroke
  lc.lineWidth = 1.5 * dpr
  lc.lineJoin = 'round'
  lc.shadowColor = `rgba(90,150,255,${0.9 * line})`
  lc.shadowBlur = 12 * dpr
  lc.stroke()
}
