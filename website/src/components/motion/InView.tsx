'use client';
import { useEffect, useRef, useState, type ReactNode } from 'react';

interface InViewProps {
  children: ReactNode;
  className?: string;
  /** Also publish scroll progress through the viewport as --progress (0 to 1). */
  progress?: boolean;
}

// Marks its box data-inview once it is on screen, so CSS can play a one-time moment.
// With `progress`, it also writes --progress while the box crosses the viewport (rAF-throttled, passive listener).
export function InView({ children, className, progress }: InViewProps) {
  const ref = useRef<HTMLDivElement>(null);
  const [seen, setSeen] = useState(false);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const io = new IntersectionObserver(([e]) => e.isIntersecting && setSeen(true), { threshold: 0.35 });
    io.observe(el);
    if (!progress) return () => io.disconnect();
    let frame = 0;
    const update = () => {
      frame = 0;
      const r = el.getBoundingClientRect();
      const vh = window.innerHeight;
      // 0 when the box's top reaches 85% of the viewport, 1 when its bottom passes 35%.
      const p = (vh * 0.85 - r.top) / (vh * 0.5 + r.height);
      el.style.setProperty('--progress', Math.min(1, Math.max(0, p)).toFixed(3));
    };
    const onScroll = () => {
      if (!frame) frame = requestAnimationFrame(update);
    };
    update();
    window.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', onScroll, { passive: true });
    return () => {
      io.disconnect();
      cancelAnimationFrame(frame);
      window.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', onScroll);
    };
  }, [progress]);

  return (
    <div ref={ref} className={className} data-inview={seen}>
      {children}
    </div>
  );
}
