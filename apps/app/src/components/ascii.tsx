import { useEffect, useRef } from 'react';
import { LAND } from '../three/land';

const RAMP = ' .:-=+*#%@';
const CHAR_ASPECT = 0.6;

type Painter = (buf: Float32Array, cols: number, rows: number, t: number) => void;

/** Текстовая графика на canvas: painter заполняет яркость клеток 0..1, символ выбирается по яркости. */
function AsciiCanvas({ cols, paint, animate = true, fps = 18, label }: { cols: number; paint: Painter; animate?: boolean; fps?: number; label?: string }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const canvas = ref.current;
    const ctx = canvas?.getContext('2d');
    if (!canvas || !ctx) return;
    let raf = 0, last = 0, visible = true, buf = new Float32Array(0), rows = 0, cell = 0;
    const still = !animate || matchMedia('(prefers-reduced-motion: reduce)').matches;

    const draw = (ms: number) => {
      buf.fill(0);
      paint(buf, cols, rows, ms / 1000);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.fillStyle = getComputedStyle(canvas).color;
      for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
        const b = buf[r * cols + c]!;
        if (b < 0.04) continue;
        // лёгкая «зернистость» стабильна для клетки, поэтому символы не мерцают
        const grain = ((c * 12.9898 + r * 78.233) % 1 + 1) % 1 * 0.1;
        const ch = RAMP[Math.min(RAMP.length - 1, Math.floor((b + grain) * RAMP.length))]!;
        if (ch === ' ') continue;
        ctx.globalAlpha = 0.35 + 0.65 * Math.min(1, b);
        ctx.fillText(ch, c * cell * CHAR_ASPECT, r * cell);
      }
      ctx.globalAlpha = 1;
    };
    const resize = () => {
      const { width, height } = canvas.getBoundingClientRect();
      if (!width || !height) return;
      const dpr = Math.min(devicePixelRatio || 1, 2);
      canvas.width = width * dpr;
      canvas.height = height * dpr;
      cell = width / cols / CHAR_ASPECT;
      rows = Math.ceil(height / cell);
      buf = new Float32Array(cols * rows);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.font = `600 ${cell}px "JetBrains Mono", ui-monospace, monospace`;
      ctx.textBaseline = 'top';
      draw(performance.now());
    };
    const tick = (ms: number) => {
      raf = requestAnimationFrame(tick);
      if (!visible || ms - last < 1000 / fps) return;
      last = ms;
      draw(ms);
    };
    const ro = new ResizeObserver(resize);
    ro.observe(canvas);
    const io = new IntersectionObserver(([e]) => { visible = !!e?.isIntersecting; });
    io.observe(canvas);
    resize();
    void document.fonts?.ready.then(resize);
    if (!still) raf = requestAnimationFrame(tick);
    return () => { cancelAnimationFrame(raf); ro.disconnect(); io.disconnect(); };
  }, [cols, paint, animate, fps]);
  return <canvas ref={ref} className="ascii-canvas" role={label ? 'img' : undefined} aria-label={label} aria-hidden={label ? undefined : true} />;
}

/* Руки строятся из «конечностей» — цепочек кругов с плавно меняющимся радиусом. Пространство 1000×500. */
type Limb = [number, number, number][];
const LEFT_HAND: Limb[] = [
  [[-80, 70, 60], [120, 112, 62], [250, 176, 60]],
  [[250, 176, 60], [352, 226, 58]],
  [[262, 214, 24], [318, 262, 20], [352, 312, 16]],
  [[300, 262, 22], [304, 322, 19], [284, 366, 14]],
  [[344, 272, 25], [360, 338, 21], [344, 396, 15]],
  [[384, 254, 27], [418, 326, 22], [414, 388, 16]],
  [[396, 216, 28], [452, 262, 21], [494, 308, 14]],
];
const RIGHT_HAND: Limb[] = [
  [[1080, 196, 62], [900, 262, 60], [800, 312, 60]],
  [[800, 312, 60], [738, 318, 54]],
  [[826, 368, 22], [820, 424, 19], [832, 468, 14]],
  [[778, 370, 25], [760, 430, 21], [768, 482, 15]],
  [[728, 352, 25], [704, 404, 20], [692, 444, 14]],
  [[782, 262, 24], [722, 248, 19], [680, 268, 15]],
  [[724, 296, 28], [650, 286, 21], [586, 292, 14]],
];
const TIP_A = [506, 310] as const;
const TIP_B = [574, 292] as const;

function drawLimb(ctx: CanvasRenderingContext2D, limb: Limb) {
  const pass = (grow: number, tone: string, lift: number) => {
    ctx.fillStyle = tone;
    for (let s = 0; s < limb.length - 1; s++) {
      const [ax, ay, ar] = limb[s]!, [bx, by, br] = limb[s + 1]!;
      const steps = Math.ceil(Math.hypot(bx - ax, by - ay) / 3);
      for (let i = 0; i <= steps; i++) {
        const k = i / steps, rad = (ar + (br - ar) * k) * grow;
        ctx.beginPath();
        ctx.arc(ax + (bx - ax) * k, ay + (by - ay) * k - lift * (ar + (br - ar) * k), Math.max(rad, 0), 0, 7);
        ctx.fill();
      }
    }
  };
  pass(1.1, '#000', 0);      // тёмная кромка отделяет пальцы друг от друга
  pass(1, '#6a6a6a', 0);     // тень
  pass(0.72, '#9a9a9a', 0.14); // основной объём
  pass(0.36, '#d0d0d0', 0.34); // блик
}

function handsMask(cols: number, rows: number) {
  const c = document.createElement('canvas');
  c.width = cols; c.height = rows;
  const ctx = c.getContext('2d', { willReadFrequently: true })!;
  ctx.fillStyle = '#000'; ctx.fillRect(0, 0, cols, rows);
  ctx.scale(cols / 1000, rows / 500);
  [...LEFT_HAND, ...RIGHT_HAND].forEach((l) => drawLimb(ctx, l));
  const px = ctx.getImageData(0, 0, cols, rows).data;
  const mask = new Float32Array(cols * rows);
  for (let i = 0; i < mask.length; i++) mask[i] = px[i * 4]! / 255;
  return mask;
}

let handsCache: { key: string; mask: Float32Array } | null = null;
const paintHands: Painter = (buf, cols, rows, t) => {
  const key = `${cols}x${rows}`;
  if (handsCache?.key !== key) handsCache = { key, mask: handsMask(cols, rows) };
  const { mask } = handsCache;
  const ax = TIP_A[0] * cols / 1000, ay = TIP_A[1] * rows / 500, bx = TIP_B[0] * cols / 1000, by = TIP_B[1] * rows / 500;
  const pulse = (t * 0.5) % 1; // сигнал бежит от пальца к пальцу и волной уходит по руке
  const px = ax + (bx - ax) * pulse, py = ay + (by - ay) * pulse;
  for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
    const i = r * cols + c;
    const m = mask[i]!;
    const dist = Math.hypot(c - (ax + bx) / 2, (r - (ay + by) / 2) / CHAR_ASPECT);
    const wave = m > 0 ? 0.16 * Math.max(0, Math.sin(dist * 0.16 - t * 2.4)) ** 6 : 0;
    const spark = Math.exp(-(((c - px) ** 2) + ((r - py) / CHAR_ASPECT) ** 2) / 2.2);
    buf[i] = Math.max(m > 0.05 ? m + wave : 0, spark);
  }
};

export function AsciiHands() {
  // на телефоне символы крупнее, иначе рисунок превращается в серую заливку
  const cols = matchMedia('(max-width: 760px)').matches ? 110 : 210;
  return <div className="ascii-hands"><AsciiCanvas cols={cols} paint={paintHands} label="Две руки из символов тянутся друг к другу" /></div>;
}

const POINTS = LAND.map(([lat, lon]) => {
  const a = lat * Math.PI / 180, o = lon * Math.PI / 180;
  return [Math.cos(a) * Math.cos(o), Math.sin(a), Math.cos(a) * Math.sin(o)] as const;
});
const TILT = 0.38;
const paintGlobe: Painter = (buf, cols, rows, t) => {
  const cy = rows / 2, cx = cols / 2;
  const radius = rows * 0.47; // в строках
  const put = (c: number, r: number, v: number) => {
    const ic = Math.round(c), ir = Math.round(r);
    if (ic < 0 || ir < 0 || ic >= cols || ir >= rows) return;
    const i = ir * cols + ic;
    if (v > buf[i]!) buf[i] = v;
  };
  // редкие точки океана, чтобы диск читался как шар, а не как кольцо материков
  for (let r = 0; r < rows; r += 2) for (let c = r % 4 ? 2 : 0; c < cols; c += 4) {
    if (Math.hypot((c - cx) * CHAR_ASPECT, r - cy) < radius) put(c, r, 0.12);
  }
  // контур сферы
  for (let a = 0; a < Math.PI * 2; a += 0.012) put(cx + Math.cos(a) * radius / CHAR_ASPECT, cy + Math.sin(a) * radius, 0.32);
  const rot = t * 0.22, sr = Math.sin(rot), cr = Math.cos(rot), st = Math.sin(TILT), ct = Math.cos(TILT);
  for (const [x, y, z] of POINTS) {
    const x1 = x * cr + z * sr, z1 = -x * sr + z * cr;
    const y2 = y * ct - z1 * st, z2 = y * st + z1 * ct;
    if (z2 <= 0) continue;
    put(cx + x1 * radius / CHAR_ASPECT, cy - y2 * radius, 0.25 + 0.75 * z2);
  }
};

export function AsciiGlobe({ cols = 72 }: { cols?: number }) {
  return <div className="ascii-globe"><AsciiCanvas cols={cols} paint={paintGlobe} /></div>;
}
