/**
 * Client-side orchestration of AI generation: outline first, then each slide.
 * Progress is per slide, so one failed slide can be retried without
 * regenerating the deck.
 */
import { useCallback, useEffect, useRef, useState } from 'react';
import { api, describeError } from './api';
import { imageForModel } from './images';
import { useStudio } from './state';
import type { GenerationImage } from '../shared/apiTypes';
import type { ImageNote, Outline, OutlineSlide, SlideContent } from '../shared/generationSchemas';
import type { Asset, BinaryStore, Project, Slide } from '../shared/model';
import { slideFromContent, slideFromOutline } from '../shared/deckBuild';
import { toParagraphs } from '../shared/textFit';
import { newId } from '../shared/util';

export interface ErrInfo {
  message: string;
  hint?: string;
  retryable: boolean;
  details?: string[];
  code?: string;
}
export interface SlideJob {
  slideId: string;
  index: number;
  title: string;
  status: 'pending' | 'running' | 'done' | 'error';
  error?: ErrInfo;
}
export interface GenState {
  phase: 'idle' | 'preparing' | 'outline' | 'slides' | 'done' | 'error' | 'cancelled';
  error?: ErrInfo;
  jobs: SlideJob[];
  notices: string[];
  model?: string;
}

async function prepareImages(assets: Asset[], store: BinaryStore, ids?: string[]): Promise<GenerationImage[]> {
  const out: GenerationImage[] = [];
  for (const a of assets) {
    if (ids && !ids.includes(a.id)) continue;
    const blob = store.get(a.id);
    if (!blob) continue;
    const img = await imageForModel(a.id, blob);
    out.push({ id: a.id, name: a.name, caption: a.caption, preferredSlide: a.preferredSlide, ...img });
  }
  return out;
}

function slideToContent(s: Slide): SlideContent {
  return {
    layout: s.layout,
    title: s.title,
    body: s.body,
    caption: s.caption,
    leftHeading: s.leftHeading,
    leftBody: s.leftBody,
    rightHeading: s.rightHeading,
    rightBody: s.rightBody,
    imageId: s.image?.assetId ?? '',
    notes: s.notes,
    flags: s.flags,
  };
}

function outlineFromDeck(p: Project): Outline {
  return {
    title: p.title,
    slides: p.slides.map((s) => ({
      layout: s.layout,
      title: s.title,
      purpose: '',
      keyPoints: toParagraphs([s.body, s.leftBody, s.rightBody, s.caption].filter(Boolean).join('\n')),
      imageIds: s.image ? [s.image.assetId] : [],
    })),
    imageNotes: [],
    missingInfo: p.generation.missingInfo,
  };
}

export function useGeneration() {
  const { project, store, update, updateSlide, select } = useStudio();
  const projectRef = useRef(project);
  projectRef.current = project;
  const outlineRef = useRef<Outline | null>(null);
  const imagesRef = useRef<GenerationImage[]>([]);
  const cancelled = useRef(false);
  const [state, setState] = useState<GenState>({ phase: 'idle', jobs: [], notices: [] });

  useEffect(() => () => void (cancelled.current = true), []);

  const setJob = (slideId: string, patch: Partial<SlideJob>) =>
    setState((s) => ({ ...s, jobs: s.jobs.map((j) => (j.slideId === slideId ? { ...j, ...patch } : j)) }));

  const runSlide = useCallback(
    async (job: { slideId: string; index: number }, planned: OutlineSlide) => {
      const outline = outlineRef.current;
      if (!outline) return;
      setJob(job.slideId, { status: 'running', error: undefined });
      try {
        const p = projectRef.current;
        const images = imagesRef.current.filter((i) => planned.imageIds.includes(i.id));
        const res = await api.slide(
          { brief: p.brief, outline, index: job.index, planned, images, imageNotes: outline.imageNotes.filter((n) => planned.imageIds.includes(n.imageId)) },
          p.assets.map((a) => a.id),
        );
        if (cancelled.current) return;
        updateSlide(job.slideId, (s) => {
          Object.assign(s, slideFromContent(res.content, s.id, s));
        });
        setJob(job.slideId, { status: 'done', title: res.content.title });
        if (res.notices.length) setState((s) => ({ ...s, notices: [...s.notices, ...res.notices] }));
      } catch (err) {
        setJob(job.slideId, { status: 'error', error: describeError(err) });
        updateSlide(job.slideId, (s) => {
          if (!s.flags.includes('Generation failed for this slide. Retry it or edit it by hand.')) s.flags.push('Generation failed for this slide. Retry it or edit it by hand.');
        });
      }
    },
    [updateSlide],
  );

  const start = useCallback(async () => {
    cancelled.current = false;
    const p = projectRef.current;
    setState({ phase: 'preparing', jobs: [], notices: [] });
    try {
      imagesRef.current = await prepareImages(p.assets, store);
      if (cancelled.current) return;
      setState((s) => ({ ...s, phase: 'outline' }));
      const res = await api.outline({ brief: p.brief, images: imagesRef.current });
      if (cancelled.current) return;
      outlineRef.current = res.outline;
      const slides = res.outline.slides.map((entry) => slideFromOutline(entry, newId('slide')));
      update((d) => {
        d.slides = slides;
        if (res.outline.title.trim()) d.title = res.outline.title.trim();
        d.generation = { mode: 'ai', provider: 'anthropic', model: res.model, generatedAt: new Date().toISOString(), missingInfo: res.outline.missingInfo };
      });
      select(slides[0]?.id ?? null);
      const jobs: SlideJob[] = slides.map((s, i) => ({ slideId: s.id, index: i, title: s.title, status: 'pending' }));
      setState({ phase: 'slides', jobs, notices: res.notices, model: res.model });
      // Two slides at a time keeps progress visible without hammering rate limits.
      let next = 0;
      const worker = async () => {
        while (!cancelled.current && next < jobs.length) {
          const i = next++;
          await runSlide(jobs[i], res.outline.slides[i]);
        }
      };
      await Promise.all([worker(), worker()]);
      if (!cancelled.current) setState((s) => ({ ...s, phase: 'done' }));
    } catch (err) {
      setState((s) => ({ ...s, phase: 'error', error: describeError(err) }));
    }
  }, [store, update, select, runSlide]);

  const retrySlide = useCallback(
    async (slideId: string) => {
      const job = state.jobs.find((j) => j.slideId === slideId);
      const outline = outlineRef.current;
      if (!job || !outline) return;
      updateSlide(slideId, (s) => {
        s.flags = s.flags.filter((f) => !f.startsWith('Generation failed'));
      });
      await runSlide(job, outline.slides[job.index]);
    },
    [state.jobs, runSlide, updateSlide],
  );

  const retryFailed = useCallback(async () => {
    for (const j of state.jobs.filter((x) => x.status === 'error')) await retrySlide(j.slideId);
  }, [state.jobs, retrySlide]);

  const cancel = useCallback(() => {
    cancelled.current = true;
    setState((s) => ({ ...s, phase: 'cancelled' }));
  }, []);

  /** Rewrites one slide with the AI, leaving every other slide untouched. */
  const regenerateSlide = useCallback(
    async (slideId: string, instruction: string) => {
      const p = projectRef.current;
      const index = p.slides.findIndex((s) => s.id === slideId);
      if (index < 0) return;
      const slide = p.slides[index];
      // Context comes from the deck as it is now (the user may have reordered or edited slides); image notes from the last outline are reused.
      const outline = { ...outlineFromDeck(p), imageNotes: outlineRef.current?.imageNotes ?? [] };
      const imageIds = slide.image ? [slide.image.assetId] : [];
      const images = await prepareImages(p.assets, store, imageIds);
      const notes: ImageNote[] = outline.imageNotes.filter((n) => imageIds.includes(n.imageId));
      const res = await api.slide(
        {
          brief: p.brief,
          outline,
          index,
          planned: { layout: slide.layout, title: slide.title, purpose: '', keyPoints: [], imageIds },
          images,
          imageNotes: notes,
          current: slideToContent(slide),
          instruction,
          deckTitles: p.slides.map((s) => s.title),
        },
        p.assets.map((a) => a.id),
      );
      updateSlide(slideId, (s) => {
        const narration = s.narration;
        Object.assign(s, slideFromContent(res.content, s.id, s));
        // Keep existing audio; it is marked outdated automatically if the notes changed.
        s.narration = narration;
      });
      update((d) => {
        d.generation.mode = d.generation.mode === 'manual' ? 'ai' : d.generation.mode;
        d.generation.model = res.model;
      });
      return res.notices;
    },
    [store, update, updateSlide],
  );

  return { state, start, retrySlide, retryFailed, cancel, regenerateSlide };
}

export type GenerationApi = ReturnType<typeof useGeneration>;
