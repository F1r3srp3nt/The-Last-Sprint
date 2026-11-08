/**
 * Spoken brief: explicit start/stop recording, then an explicit "Transcribe"
 * click (ElevenLabs speech-to-text, uses credits), then an editable transcript
 * the user confirms before it touches the brief. Nothing records in the background.
 */
import { useEffect, useRef, useState } from 'react';
import { api, describeError } from '../api';
import type { ErrInfo } from '../generation';

type Phase = 'idle' | 'recording' | 'recorded' | 'transcribing' | 'transcript';
const MAX_SECONDS = 300;

function pickMime(): string {
  const options = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus'];
  return options.find((t) => typeof MediaRecorder !== 'undefined' && MediaRecorder.isTypeSupported(t)) ?? '';
}

export function SpokenBrief({
  available,
  verified,
  onOpenSetup,
  onUse,
}: {
  available: boolean;
  verified: boolean | null;
  onOpenSetup: () => void;
  onUse: (text: string, mode: 'replace' | 'append') => void;
}) {
  const [phase, setPhase] = useState<Phase>('idle');
  const [seconds, setSeconds] = useState(0);
  const [audio, setAudio] = useState<Blob | null>(null);
  const [audioUrl, setAudioUrl] = useState<string | null>(null);
  const [transcript, setTranscript] = useState('');
  const [error, setError] = useState<ErrInfo | null>(null);
  const recorder = useRef<MediaRecorder | null>(null);
  const stream = useRef<MediaStream | null>(null);
  const timer = useRef<number | null>(null);

  const stopTracks = () => {
    stream.current?.getTracks().forEach((t) => t.stop());
    stream.current = null;
    if (timer.current) window.clearInterval(timer.current);
    timer.current = null;
  };
  useEffect(() => () => {
    if (recorder.current && recorder.current.state !== 'inactive') recorder.current.stop();
    stopTracks();
  }, []);
  useEffect(() => () => {
    if (audioUrl) URL.revokeObjectURL(audioUrl);
  }, [audioUrl]);

  async function start() {
    setError(null);
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') {
      setError({ message: 'This browser cannot record audio.', hint: 'Use a current Chrome, Edge, Firefox or Safari, or type the brief.', retryable: false });
      return;
    }
    try {
      stream.current = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (e) {
      const denied = (e as DOMException).name === 'NotAllowedError';
      setError({
        message: denied ? 'Microphone access was blocked.' : 'No microphone could be opened.',
        hint: denied ? 'Allow microphone access for this page in the browser\'s site settings, then try again.' : 'Check that a microphone is connected.',
        retryable: true,
      });
      return;
    }
    const mime = pickMime();
    const rec = new MediaRecorder(stream.current, mime ? { mimeType: mime } : undefined);
    const chunks: Blob[] = [];
    rec.ondataavailable = (e) => e.data.size && chunks.push(e.data);
    rec.onstop = () => {
      stopTracks();
      const blob = new Blob(chunks, { type: rec.mimeType || mime || 'audio/webm' });
      setAudio(blob);
      setAudioUrl(URL.createObjectURL(blob));
      setPhase('recorded');
    };
    recorder.current = rec;
    rec.start(1000);
    setSeconds(0);
    setPhase('recording');
    timer.current = window.setInterval(() => {
      setSeconds((s) => {
        if (s + 1 >= MAX_SECONDS && rec.state === 'recording') rec.stop();
        return s + 1;
      });
    }, 1000);
  }

  function stop() {
    if (recorder.current?.state === 'recording') recorder.current.stop();
  }

  async function transcribe() {
    if (!audio) return;
    setPhase('transcribing');
    setError(null);
    try {
      const ext = audio.type.includes('mp4') ? 'm4a' : audio.type.includes('ogg') ? 'ogg' : 'webm';
      const res = await api.transcribe(audio, `spoken-brief.${ext}`);
      if (!res.text) {
        setError({ message: 'No speech was recognised in the recording.', hint: 'Record again, closer to the microphone.', retryable: true });
        setPhase('recorded');
        return;
      }
      setTranscript(res.text);
      setPhase('transcript');
    } catch (e) {
      setError(describeError(e));
      setPhase('recorded');
    }
  }

  function discard() {
    setAudio(null);
    setAudioUrl(null);
    setTranscript('');
    setError(null);
    setPhase('idle');
  }

  const mmss = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;

  return (
    <div className="card spoken" aria-label="Spoken brief">
      <div className="card-head">
        <h3>Speak your brief instead</h3>
        <span className="pill small">ElevenLabs speech-to-text</span>
      </div>
      {!available ? (
        <p className="muted small">
          ElevenLabs is not configured, so recording is off. Typing works as normal.{' '}
          <button className="link" onClick={onOpenSetup}>
            How to set it up
          </button>
        </p>
      ) : (
        <>
          <p className="muted small">
            Recording starts only when you press <b>Start recording</b> and stops when you press <b>Stop</b> (max 5 min). Nothing is sent until you press{' '}
            <b>Transcribe</b>. Transcription sends the audio to ElevenLabs and uses your ElevenLabs credits.
            {verified === false && ' The last connection check failed; see Setup.'}
          </p>
          <div className="row gap-s wrap">
            {phase === 'idle' && (
              <button className="btn" onClick={start}>
                ● Start recording
              </button>
            )}
            {phase === 'recording' && (
              <>
                <span className="rec-dot" aria-hidden />
                <span className="mono" aria-live="polite">
                  Recording {mmss}
                </span>
                <button className="btn primary" onClick={stop}>
                  ■ Stop
                </button>
              </>
            )}
            {(phase === 'recorded' || phase === 'transcribing') && audioUrl && (
              <>
                <audio src={audioUrl} controls className="audio-inline" />
                <button className="btn primary" onClick={transcribe} disabled={phase === 'transcribing'}>
                  {phase === 'transcribing' ? 'Transcribing…' : 'Transcribe (uses credits)'}
                </button>
                <button className="btn ghost" onClick={discard} disabled={phase === 'transcribing'}>
                  Discard
                </button>
              </>
            )}
          </div>
          {phase === 'transcript' && (
            <div className="transcript">
              <label className="field">
                <span>Transcript — edit it, then choose how to use it</span>
                <textarea value={transcript} onChange={(e) => setTranscript(e.target.value)} rows={5} data-testid="transcript" />
              </label>
              <div className="row gap-s wrap">
                <button className="btn primary" onClick={() => { onUse(transcript, 'replace'); discard(); }} disabled={!transcript.trim()}>
                  Use as brief (replace)
                </button>
                <button className="btn" onClick={() => { onUse(transcript, 'append'); discard(); }} disabled={!transcript.trim()}>
                  Append to brief
                </button>
                <button className="btn ghost" onClick={discard}>
                  Discard
                </button>
              </div>
            </div>
          )}
        </>
      )}
      {error && (
        <div className="alert error" role="alert">
          <b>{error.message}</b> {error.hint}
        </div>
      )}
    </div>
  );
}
