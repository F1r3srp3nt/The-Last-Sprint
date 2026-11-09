export function newId(prefix: string): string {
  const c = globalThis.crypto;
  const raw =
    c && typeof c.randomUUID === 'function'
      ? c.randomUUID().replace(/-/g, '').slice(0, 12)
      : Math.random().toString(36).slice(2, 14);
  return `${prefix}_${raw}`;
}

/** FNV-1a 32-bit hash of normalised text. Used to detect when speaker notes changed after narration was made. */
export function textHash(text: string): string {
  const normalised = text.replace(/\s+/g, ' ').trim();
  let h = 0x811c9dc5;
  for (let i = 0; i < normalised.length; i++) {
    h ^= normalised.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16).padStart(8, '0');
}

/** File-name-safe slug. */
export function slugify(text: string, fallback = 'presentation'): string {
  const s = text
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60);
  return s || fallback;
}

export function pad2(n: number): string {
  return String(n).padStart(2, '0');
}

/** Wraps bytes in a Blob (works in browsers and Node 18+). */
export function bytesToBlob(bytes: Uint8Array, type: string): Blob {
  return new Blob([bytes as Uint8Array<ArrayBuffer>], { type });
}

/** Normalised form used to spot repeated messages ("No figures were given." vs "no figures were given"). */
function messageKey(text: string): string {
  return text
    .toLowerCase()
    .replace(/[“”"'`]/g, '')
    .replace(/[\s.!,;:]+/g, ' ')
    .trim();
}

/** Drops empty and repeated messages, keeping the first wording and the original order. */
export function uniqueMessages(messages: readonly string[], alreadyShown: readonly string[] = []): string[] {
  const seen = new Set(alreadyShown.map(messageKey));
  const out: string[] = [];
  for (const m of messages) {
    const text = m.trim();
    const key = messageKey(text);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push(text);
  }
  return out;
}
