import { useRef, useState, type DragEvent } from 'react';
import { useStudio } from '../state';
import { ACCEPTED_TYPES, blobUrl, formatBytes, readImageFile } from '../images';

export function SourcesStep({ onNext }: { onNext: () => void }) {
  const { project, store, update, putBinary, dropBinary, toast } = useStudio();
  const [over, setOver] = useState(false);
  const [dragIndex, setDragIndex] = useState<number | null>(null);
  const input = useRef<HTMLInputElement>(null);
  const usedBy = (id: string) => project.slides.filter((s) => s.image?.assetId === id).length;

  async function addFiles(files: FileList | File[]) {
    const list = Array.from(files);
    let added = 0;
    for (const f of list) {
      try {
        const { asset, blob } = await readImageFile(f);
        putBinary(asset.id, blob);
        update((d) => {
          d.assets.push(asset);
        });
        added++;
      } catch (e) {
        toast('error', (e as Error).message, 'Accepted: PNG, JPEG and WebP up to 25 MB.');
      }
    }
    if (added) toast('success', `Added ${added} image${added === 1 ? '' : 's'}.`);
  }

  function onDrop(e: DragEvent) {
    e.preventDefault();
    setOver(false);
    if (e.dataTransfer.files.length) void addFiles(e.dataTransfer.files);
  }

  function move(from: number, to: number) {
    if (to < 0 || to >= project.assets.length || from === to) return;
    update((d) => {
      const [a] = d.assets.splice(from, 1);
      d.assets.splice(to, 0, a);
    });
  }

  function remove(id: string) {
    const n = usedBy(id);
    if (n && !confirm(`This image is used on ${n} slide(s). Remove it from the project and those slides?`)) return;
    update((d) => {
      d.assets = d.assets.filter((a) => a.id !== id);
      for (const s of d.slides) if (s.image?.assetId === id) s.image = null;
    });
    dropBinary(id);
  }

  const slideOptions = Math.max(project.brief.slideCount, project.slides.length);

  return (
    <section className="step step-sources" aria-labelledby="sources-h">
      <header className="step-head">
        <div>
          <h2 id="sources-h">1 · Images</h2>
          <p className="muted">Add the images for your deck. Originals are kept exactly as uploaded and are never stretched. Images are optional.</p>
        </div>
        <button className="btn primary" onClick={onNext}>
          Continue to brief →
        </button>
      </header>

      <div
        className={`dropzone ${over ? 'over' : ''}`}
        onDragOver={(e) => {
          e.preventDefault();
          setOver(true);
        }}
        onDragLeave={() => setOver(false)}
        onDrop={onDrop}
        onClick={() => input.current?.click()}
        role="button"
        tabIndex={0}
        onKeyDown={(e) => (e.key === 'Enter' || e.key === ' ') && input.current?.click()}
        aria-label="Upload images"
      >
        <div className="dz-icon" aria-hidden>
          ⇪
        </div>
        <strong>Drop PNG, JPEG or WebP images here</strong>
        <span className="muted">or click to choose files · several at once is fine</span>
        <input
          ref={input}
          type="file"
          accept={ACCEPTED_TYPES.join(',')}
          multiple
          hidden
          data-testid="file-input"
          onChange={(e) => {
            if (e.target.files) void addFiles(e.target.files);
            e.target.value = '';
          }}
        />
      </div>

      {project.assets.length > 0 && (
        <ol className="gallery" aria-label="Uploaded images">
          {project.assets.map((a, i) => (
            <li
              key={a.id}
              className={`gallery-item ${dragIndex === i ? 'dragging' : ''}`}
              draggable
              onDragStart={() => setDragIndex(i)}
              onDragEnd={() => setDragIndex(null)}
              onDragOver={(e) => e.preventDefault()}
              onDrop={(e) => {
                e.preventDefault();
                e.stopPropagation();
                if (dragIndex !== null) move(dragIndex, i);
                setDragIndex(null);
              }}
              data-testid="gallery-item"
            >
              <div className="thumb">
                <img src={blobUrl(store.get(a.id))} alt={a.caption || a.name} />
                <span className="badge">{i + 1}</span>
              </div>
              <div className="gallery-meta">
                <div className="name" title={a.name}>
                  {a.name}
                </div>
                <div className="muted small">
                  {a.width}×{a.height} · {a.mime.replace('image/', '').toUpperCase()} · {formatBytes(a.bytes)}
                </div>
                <label className="field compact">
                  <span>Caption (optional)</span>
                  <input
                    value={a.caption}
                    placeholder="What does this image show?"
                    onChange={(e) =>
                      update((d) => {
                        d.assets[i].caption = e.target.value;
                      })
                    }
                  />
                </label>
                <label className="field compact">
                  <span>Placement</span>
                  <select
                    value={a.preferredSlide ?? ''}
                    onChange={(e) =>
                      update((d) => {
                        d.assets[i].preferredSlide = e.target.value ? Number(e.target.value) : null;
                      })
                    }
                  >
                    <option value="">Let the generator suggest</option>
                    {Array.from({ length: slideOptions }, (_, n) => (
                      <option key={n} value={n + 1}>
                        Slide {n + 1}
                      </option>
                    ))}
                  </select>
                </label>
                <div className="row gap-s">
                  <button className="btn icon" onClick={() => move(i, i - 1)} disabled={i === 0} aria-label={`Move ${a.name} earlier`} title="Move earlier">
                    ←
                  </button>
                  <button className="btn icon" onClick={() => move(i, i + 1)} disabled={i === project.assets.length - 1} aria-label={`Move ${a.name} later`} title="Move later">
                    →
                  </button>
                  <span className="spacer" />
                  {usedBy(a.id) > 0 && <span className="pill small">on {usedBy(a.id)} slide(s)</span>}
                  <button className="btn ghost danger" onClick={() => remove(a.id)} aria-label={`Remove ${a.name}`}>
                    Remove
                  </button>
                </div>
              </div>
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}
