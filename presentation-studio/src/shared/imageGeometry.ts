/**
 * Image placement maths shared by the preview and the PowerPoint export.
 * Images keep their aspect ratio in every mode: they are never stretched.
 * All rectangles are in inches on a 13.333 x 7.5 in (16:9) slide.
 */
import type { ImagePlacement } from './model';

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface ImageGeometry {
  /** Frame the image is clipped to. */
  frame: Rect;
  /** Where the whole, uncropped image is drawn. Extends past the frame in fill mode. */
  draw: Rect;
  /** Visible part of the scaled image, relative to `draw`'s top-left. Only in fill mode. */
  crop: Rect | null;
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, v));
}

export function computeImageGeometry(
  frame: Rect,
  natural: { width: number; height: number },
  placement: Pick<ImagePlacement, 'mode' | 'zoom' | 'focusX' | 'focusY'>,
): ImageGeometry {
  const iw = natural.width;
  const ih = natural.height;
  if (placement.mode === 'fit') {
    const s = Math.min(frame.w / iw, frame.h / ih);
    const w = iw * s;
    const h = ih * s;
    const draw = { x: frame.x + (frame.w - w) / 2, y: frame.y + (frame.h - h) / 2, w, h };
    return { frame, draw, crop: null };
  }
  const zoom = clamp(placement.zoom, 1, 3);
  const s = Math.max(frame.w / iw, frame.h / ih) * zoom;
  const w = iw * s;
  const h = ih * s;
  const ox = clamp(placement.focusX * w - frame.w / 2, 0, Math.max(0, w - frame.w));
  const oy = clamp(placement.focusY * h - frame.h / 2, 0, Math.max(0, h - frame.h));
  return {
    frame,
    draw: { x: frame.x - ox, y: frame.y - oy, w, h },
    crop: { x: ox, y: oy, w: frame.w, h: frame.h },
  };
}
