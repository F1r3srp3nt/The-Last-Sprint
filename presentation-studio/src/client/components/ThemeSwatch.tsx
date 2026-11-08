import type { ThemeId } from '../../shared/model';
import { THEMES } from '../../shared/themes';

export function ThemeSwatch({ themeId }: { themeId: ThemeId }) {
  const t = THEMES[themeId];
  return (
    <span className="swatch" style={{ background: `#${t.background}` }} aria-hidden>
      <span className="swatch-title" style={{ background: `#${t.title}` }} />
      <span className="swatch-accent" style={{ background: `#${t.accent}` }} />
      <span className="swatch-text" style={{ background: `#${t.text}` }} />
    </span>
  );
}
