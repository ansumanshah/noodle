'use client';
import { useEffect, useRef, useState } from 'react';

const question = 'Summarise this clause in plain words.';
const answer = 'You can cancel with 30 days’ notice. Any months you paid ahead are refunded.';

type Phase = 'waiting' | 'streaming' | 'done' | 'asleep';

// A reply streams in word by word once the card is on screen, then the model goes to sleep and gives its memory back.
// Under Reduce Motion the full reply shows at once; the sleep state still follows.
export function ChatDemo() {
  const ref = useRef<HTMLDivElement>(null);
  const [phase, setPhase] = useState<Phase>('waiting');
  const [words, setWords] = useState(0);
  const total = answer.split(' ').length;

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const timers: ReturnType<typeof setTimeout>[] = [];
    const io = new IntersectionObserver(([e]) => {
      if (!e.isIntersecting) return;
      io.disconnect();
      const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
      setPhase('streaming');
      const step = still ? 0 : 70;
      for (let i = 1; i <= total; i++) timers.push(setTimeout(() => setWords(i), 500 + i * step));
      const end = 500 + total * step;
      timers.push(setTimeout(() => setPhase('done'), end));
      timers.push(setTimeout(() => setPhase('asleep'), end + 3500));
    }, { threshold: 0.5 });
    io.observe(el);
    return () => {
      io.disconnect();
      timers.forEach(clearTimeout);
    };
  }, [total]);

  const shown = answer.split(' ').slice(0, words).join(' ');
  return (
    <div ref={ref} className="chat-demo mx-auto max-w-xl rounded-card border border-line bg-raised p-5 text-left shadow-[var(--shadow)]" data-phase={phase}>
      <p className="ml-auto w-fit max-w-[85%] rounded-card rounded-br-md bg-surface px-4 py-2 text-sm">{question}</p>
      <p className="mt-3 min-h-[3em] max-w-[90%] text-[0.95rem] leading-relaxed" aria-live="polite">
        {shown}
        {phase === 'streaming' ? <span className="chat-caret ml-0.5 inline-block h-[1em] w-[2px] translate-y-[2px] bg-[var(--models)]" aria-hidden="true" /> : null}
      </p>
      <div className="mt-4 flex items-center gap-2 border-t border-line pt-3 text-xs text-muted">
        <span className="chat-state-dot size-2 rounded-full" aria-hidden="true" />
        <span>
          {phase === 'asleep' ? 'Model asleep. Memory given back to your Mac.' : phase === 'waiting' ? 'Model ready' : 'Running on this Mac, offline'}
        </span>
      </div>
    </div>
  );
}
