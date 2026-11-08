import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from 'react';
import { emptyProject, type BinaryStore, type Project, type Slide } from '../shared/model';

export interface Toast {
  id: number;
  kind: 'info' | 'success' | 'error';
  message: string;
  hint?: string;
}

interface StudioContextValue {
  project: Project;
  store: BinaryStore;
  /** Increments whenever the binary store changes, so components re-render. */
  storeVersion: number;
  dirty: boolean;
  update: (fn: (draft: Project) => void) => void;
  updateSlide: (id: string, fn: (s: Slide) => void) => void;
  putBinary: (id: string, blob: Blob) => void;
  dropBinary: (id: string) => void;
  replaceAll: (project: Project, store: BinaryStore) => void;
  markSaved: () => void;
  selectedId: string | null;
  select: (id: string | null) => void;
  toasts: Toast[];
  toast: (kind: Toast['kind'], message: string, hint?: string) => void;
  dismissToast: (id: number) => void;
}

const StudioContext = createContext<StudioContextValue | null>(null);

export function StudioProvider({ children }: { children: ReactNode }) {
  const [project, setProject] = useState<Project>(() => emptyProject());
  const storeRef = useRef<BinaryStore>(new Map());
  const [storeVersion, setStoreVersion] = useState(0);
  const [dirty, setDirty] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [toasts, setToasts] = useState<Toast[]>([]);
  const toastId = useRef(0);

  const update = useCallback((fn: (draft: Project) => void) => {
    setProject((prev) => {
      const draft = structuredClone(prev);
      fn(draft);
      return draft;
    });
    setDirty(true);
  }, []);

  const updateSlide = useCallback(
    (id: string, fn: (s: Slide) => void) =>
      update((d) => {
        const s = d.slides.find((x) => x.id === id);
        if (s) fn(s);
      }),
    [update],
  );

  const putBinary = useCallback((id: string, blob: Blob) => {
    storeRef.current.set(id, blob);
    setStoreVersion((v) => v + 1);
  }, []);
  const dropBinary = useCallback((id: string) => {
    storeRef.current.delete(id);
    setStoreVersion((v) => v + 1);
  }, []);
  const replaceAll = useCallback((p: Project, store: BinaryStore) => {
    storeRef.current = store;
    setProject(p);
    setStoreVersion((v) => v + 1);
    setSelectedId(p.slides[0]?.id ?? null);
    setDirty(false);
  }, []);

  const dismissToast = useCallback((id: number) => setToasts((t) => t.filter((x) => x.id !== id)), []);
  const toast = useCallback(
    (kind: Toast['kind'], message: string, hint?: string) => {
      const id = ++toastId.current;
      setToasts((t) => [...t.slice(-3), { id, kind, message, hint }]);
      setTimeout(() => dismissToast(id), kind === 'error' ? 12000 : 5000);
    },
    [dismissToast],
  );

  const value = useMemo<StudioContextValue>(
    () => ({
      project,
      store: storeRef.current,
      storeVersion,
      dirty,
      update,
      updateSlide,
      putBinary,
      dropBinary,
      replaceAll,
      markSaved: () => setDirty(false),
      selectedId,
      select: setSelectedId,
      toasts,
      toast,
      dismissToast,
    }),
    [project, storeVersion, dirty, update, updateSlide, putBinary, dropBinary, replaceAll, selectedId, toasts, toast, dismissToast],
  );
  return <StudioContext.Provider value={value}>{children}</StudioContext.Provider>;
}

export function useStudio(): StudioContextValue {
  const ctx = useContext(StudioContext);
  if (!ctx) throw new Error('useStudio outside StudioProvider');
  return ctx;
}
