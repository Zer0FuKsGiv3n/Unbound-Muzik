// Unbound Muzik — code-drawn covers for tracks without art.
// A gradient + a simple shape, drawn on a plain 2D canvas, different per
// track, so a track with no thumbnail still has a distinct, attractive
// tile instead of a grey box. No 3D, no library, no network.

function hashString(value: string): number {
  let hash = 0;
  for (let i = 0; i < value.length; i++) {
    hash = (hash * 31 + value.charCodeAt(i)) | 0;
  }
  return Math.abs(hash);
}

/** Two hues for a track, derived from its id/title — stable per track. */
export function coverHues(seed: string): [number, number] {
  const hash = hashString(seed);
  const hueA = hash % 360;
  const hueB = (hueA + 50 + (hash % 60)) % 360;
  return [hueA, hueB];
}

/** CSS gradient for a tile. Used where an <img> is not needed. */
export function coverGradient(seed: string): string {
  const [a, b] = coverHues(seed);
  return `linear-gradient(135deg, hsl(${a} 75% 45%), hsl(${b} 80% 55%))`;
}

/**
 * A small painted cover as a data URL, for places that need an image
 * (Media Session artwork). Drawn once per track, cached in memory.
 */
const cache = new Map<string, string>();

export function coverDataUrl(seed: string, size = 256): string {
  const cached = cache.get(seed);
  if (cached) return cached;
  const [a, b] = coverHues(seed);
  const canvas = document.createElement('canvas');
  canvas.width = size;
  canvas.height = size;
  const ctx = canvas.getContext('2d');
  if (!ctx) return '';
  const gradient = ctx.createLinearGradient(0, 0, size, size);
  gradient.addColorStop(0, `hsl(${a} 75% 45%)`);
  gradient.addColorStop(1, `hsl(${b} 80% 55%)`);
  ctx.fillStyle = gradient;
  ctx.fillRect(0, 0, size, size);
  // One soft circle, like a record in the corner.
  ctx.beginPath();
  ctx.arc(size * 0.72, size * 0.28, size * 0.34, 0, Math.PI * 2);
  ctx.fillStyle = 'rgba(255, 255, 255, 0.14)';
  ctx.fill();
  ctx.beginPath();
  ctx.arc(size * 0.72, size * 0.28, size * 0.1, 0, Math.PI * 2);
  ctx.fillStyle = 'rgba(5, 5, 5, 0.55)';
  ctx.fill();
  const url = canvas.toDataURL('image/png');
  cache.set(seed, url);
  return url;
}
