'use client';
import { useEffect, useRef, type ReactNode } from 'react';

interface RevealProps {
  children: ReactNode;
  delay?: number;
  className?: string;
}

// Reveals once with transform and opacity only, driven by IntersectionObserver + CSS transitions.
// Reduce Motion skips the vertical offset and fades cleanly.
export function Reveal({ children, delay = 0, className }: RevealProps) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      el.setAttribute('data-reveal', 'shown');
      return;
    }
    const io = new IntersectionObserver(
      ([entry]) => {
        if (!entry.isIntersecting) return;
        io.disconnect();
        el.setAttribute('data-reveal', 'shown');
      },
      { rootMargin: '0px 0px -6% 0px' },
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);

  return (
    <div
      ref={ref}
      data-reveal=""
      className={className}
      style={delay ? { transitionDelay: `${Math.round(delay * 1000)}ms` } : undefined}
    >
      {children}
    </div>
  );
}
