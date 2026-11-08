/** Narration (ElevenLabs text-to-speech) from speaker notes. Every call is triggered by an explicit user action. */
import { useCallback, useRef, useState } from 'react';
import { api, describeError } from './api';
import type { ErrInfo } from './generation';
import { useStudio } from './state';
import type { Voice } from '../shared/apiTypes';
import { narrationText } from '../shared/narration';
import { newId, textHash } from '../shared/util';

export interface DeckNarrationProgress {
  running: boolean;
  done: number;
  total: number;
  failed: { slideId: string; error: ErrInfo }[];
  stoppedReason?: string;
}

const FATAL = new Set(['elevenlabs_auth', 'elevenlabs_permission', 'elevenlabs_credits', 'elevenlabs_not_configured', 'elevenlabs_voice_unavailable', 'server_unreachable']);

export function useNarration() {
  const { project, store, updateSlide, putBinary, dropBinary, update } = useStudio();
  const projectRef = useRef(project);
  projectRef.current = project;
  const [voices, setVoices] = useState<Voice[] | null>(null);
  const [voicesError, setVoicesError] = useState<ErrInfo | null>(null);
  const [busy, setBusy] = useState<Set<string>>(new Set());
  const [errors, setErrors] = useState<Record<string, ErrInfo>>({});
  const [deck, setDeck] = useState<DeckNarrationProgress>({ running: false, done: 0, total: 0, failed: [] });
  const stopDeck = useRef(false);

  const loadVoices = useCallback(async () => {
    setVoicesError(null);
    try {
      const v = await api.voices();
      setVoices(v);
      return v;
    } catch (e) {
      setVoicesError(describeError(e));
      return null;
    }
  }, []);

  const chooseVoice = useCallback(
    (voice: Voice | null) =>
      update((d) => {
        d.narration.voiceId = voice?.voiceId ?? null;
        d.narration.voiceName = voice?.name ?? null;
      }),
    [update],
  );

  const narrateSlide = useCallback(
    async (slideId: string): Promise<ErrInfo | null> => {
      const p = projectRef.current;
      const slide = p.slides.find((s) => s.id === slideId);
      const voiceId = p.narration.voiceId;
      if (!slide || !voiceId) return { message: 'Choose a voice first.', retryable: false };
      const text = narrationText(slide);
      setBusy((b) => new Set(b).add(slideId));
      setErrors(({ [slideId]: _, ...rest }) => rest);
      try {
        const { blob, model } = await api.tts(voiceId, text, p.narration.modelId ?? undefined);
        const audioId = newId('aud');
        putBinary(audioId, blob);
        const old = slide.narration?.audioId;
        updateSlide(slideId, (s) => {
          s.narration = {
            audioId,
            notesHash: textHash(text),
            voiceId,
            voiceName: p.narration.voiceName ?? voiceId,
            modelId: model,
            characters: text.length,
            createdAt: new Date().toISOString(),
            mime: blob.type || 'audio/mpeg',
          };
        });
        if (old) dropBinary(old);
        return null;
      } catch (e) {
        const err = describeError(e);
        setErrors((x) => ({ ...x, [slideId]: err }));
        return err;
      } finally {
        setBusy((b) => {
          const n = new Set(b);
          n.delete(slideId);
          return n;
        });
      }
    },
    [putBinary, dropBinary, updateSlide],
  );

  const narrateSlides = useCallback(
    async (ids: string[]) => {
      stopDeck.current = false;
      setDeck({ running: true, done: 0, total: ids.length, failed: [] });
      for (const id of ids) {
        if (stopDeck.current) break;
        const err = await narrateSlide(id);
        setDeck((d) => ({ ...d, done: d.done + 1, failed: err ? [...d.failed, { slideId: id, error: err }] : d.failed }));
        // Stop early on errors that would repeat for every remaining slide.
        if (err && FATAL.has(err.code ?? '')) {
          setDeck((d) => ({ ...d, stoppedReason: err.message }));
          break;
        }
      }
      setDeck((d) => ({ ...d, running: false }));
    },
    [narrateSlide],
  );

  const removeNarration = useCallback(
    (slideId: string) => {
      const s = projectRef.current.slides.find((x) => x.id === slideId);
      if (!s?.narration) return;
      const id = s.narration.audioId;
      updateSlide(slideId, (x) => void (x.narration = null));
      dropBinary(id);
    },
    [updateSlide, dropBinary],
  );

  return {
    voices,
    voicesError,
    loadVoices,
    chooseVoice,
    narrateSlide,
    narrateSlides,
    stopDeck: () => (stopDeck.current = true),
    removeNarration,
    busy,
    errors,
    deck,
    audioFor: (audioId: string | undefined) => (audioId ? store.get(audioId) : undefined),
  };
}

export type NarrationApi = ReturnType<typeof useNarration>;
