import { useEffect, useRef, useState } from 'react';
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

/* Руки берутся из маски /hands-mask.png, вырезанной из исходной ASCII-картинки. Координаты маски — 2000×820. */
const TIP_A = [905, 442] as const;
const TIP_B = [1160, 405] as const;
const PULSE_SECONDS = 4.2;
const REVEAL_SECONDS = 1.8;

function handsPainter(source: HTMLImageElement): Painter {
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  let cache: { key: string; mask: Float32Array } | null = null;
  let start: number | null = null;
  return (buf, cols, rows, t) => {
    const key = `${cols}x${rows}`;
    if (cache?.key !== key) {
      const c = document.createElement('canvas');
      c.width = cols; c.height = rows;
      const ctx = c.getContext('2d', { willReadFrequently: true })!;
      ctx.drawImage(source, 0, 0, cols, rows);
      const px = ctx.getImageData(0, 0, cols, rows).data;
      const mask = new Float32Array(cols * rows);
      for (let i = 0; i < mask.length; i++) mask[i] = Math.min(1, px[i * 4]! / 255 * 2.4);
      cache = { key, mask };
    }
    const { mask } = cache;
    start ??= t;
    const age = reduced ? 1e3 : t - start;
    const ax = TIP_A[0] * cols / 2000, ay = TIP_A[1] * rows / 820, bx = TIP_B[0] * cols / 2000, by = TIP_B[1] * rows / 820;
    const gapX = (ax + bx) / 2, gapY = (ay + by) / 2;
    const reveal = 1 - (1 - Math.min(1, age / REVEAL_SECONDS)) ** 3;
    // Цикл: сигнал перелетает от пальца к пальцу (первые 30%), затем волна расходится по обеим рукам.
    const phase = age < REVEAL_SECONDS ? -1 : ((age - REVEAL_SECONDS) % PULSE_SECONDS) / PULSE_SECONDS;
    const flight = phase >= 0 && phase < 0.3 ? phase / 0.3 : -1;
    const waveAt = phase >= 0.3 ? (phase - 0.3) / 0.7 : -1;
    const waveR = waveAt * Math.max(cols, rows / CHAR_ASPECT) * 0.6;
    for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) {
      const i = r * cols + c;
      const m = mask[i]!;
      const dx = c - gapX, dy = (r - gapY) / CHAR_ASPECT, dist = Math.hypot(dx, dy);
      let v = 0;
      if (m > 0.06) {
        // Появление: рисунок проступает от краёв экрана к пальцам, граница неровная, как у помех.
        const edge = Math.abs(dx) / (cols / 2) + 0.06 * Math.sin(r * 1.7 + c * 0.3);
        if (edge > 1 - reveal * 1.15) {
          const shimmer = reduced ? 0 : 0.07 * Math.sin(c * 0.9 + r * 1.3 + t * 1.6);
          const wave = waveAt >= 0 ? 0.5 * (1 - waveAt) * Math.exp(-(((dist - waveR) / 5) ** 2)) : 0;
          v = m + shimmer + wave;
        }
      }
      if (flight >= 0) {
        for (let k = 0; k < 5; k++) { // голова сигнала и затухающий хвост
          const p = flight - k * 0.045;
          if (p < 0) break;
          const px = ax + (bx - ax) * p, py = ay + (by - ay) * p;
          const g = Math.exp(-(((c - px) ** 2) + ((r - py) / CHAR_ASPECT) ** 2) / 1.6) * (1 - k * 0.18);
          if (g > v) v = g;
        }
      }
      buf[i] = v;
    }
  };
}

export function AsciiHands() {
  // На телефоне символы крупнее, иначе рисунок превращается в серую заливку
  const cols = matchMedia('(max-width: 760px)').matches ? 120 : 240;
  const [paint, setPaint] = useState<Painter | null>(null);
  useEffect(() => {
    let alive = true;
    const img = new Image();
    img.onload = () => { if (alive) setPaint(() => handsPainter(img)); };
    img.src = '/hands-mask.png';
    return () => { alive = false; };
  }, []);
  return <div className="ascii-hands">{paint && <AsciiCanvas cols={cols} paint={paint} fps={24} label="Две руки из символов тянутся друг к другу, между пальцами пробегает сигнал" />}</div>;
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
