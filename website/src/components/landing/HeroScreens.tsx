'use client';
import Link from 'next/link';
import { useRef, useState, type KeyboardEvent } from 'react';
import { Stats } from '@/components/product/Stats';
import type { Shot } from '@/lib/media';
import type { Stat } from '@/lib/product-pages';
import type { Product } from '@/lib/site';
import { ProductIcon } from './ProductIcon';

export interface HeroScreen {
  id: Product['id'];
  label: string;
  caption: string;
  shot: Shot;
  alt: string;
  stats: Stat[];
}

interface HeroScreensProps {
  screens: HeroScreen[];
}

// One app, three screens. Tabs follow ARIA tablist keyboard semantics (roving tabIndex, selection
// follows focus, border-based active underline) with no auto-advance timer taking the frame away.
export function HeroScreens({ screens }: HeroScreensProps) {
  const [active, setActive] = useState(0);
  const tabRefs = useRef<(HTMLButtonElement | null)[]>([]);

  const selectTab = (index: number) => {
    setActive(index);
    tabRefs.current[index]?.focus();
  };

  const onKeyDown = (e: KeyboardEvent<HTMLButtonElement>, i: number) => {
    let next = -1;
    if (e.key === 'ArrowRight') next = (i + 1) % screens.length;
    else if (e.key === 'ArrowLeft') next = (i - 1 + screens.length) % screens.length;
    else if (e.key === 'Home') next = 0;
    else if (e.key === 'End') next = screens.length - 1;
    if (next < 0) return;
    e.preventDefault();
    selectTab(next);
  };

  const current = screens[active];

  return (
    <div>
      <div
        role="tablist"
        aria-label="Product screens"
        className="tab-strip flex flex-nowrap items-center justify-start gap-1 overflow-x-auto sm:gap-2 pb-1 sm:justify-center"
      >
        {screens.map((s, i) => {
          const on = i === active;
          return (
            <button
              key={s.id}
              ref={(el) => {
                tabRefs.current[i] = el;
              }}
              type="button"
              role="tab"
              id={`screen-tab-${s.id}`}
              aria-selected={on}
              tabIndex={on ? 0 : -1}
              onClick={() => setActive(i)}
              onKeyDown={(e) => onKeyDown(e, i)}
              className={`tone-${s.id} tab-btn chip-select spring press inline-flex h-control shrink-0 items-center gap-1.5 rounded-panel pr-2 pl-1 text-[0.8125rem] font-semibold sm:gap-2 sm:pr-3.5 sm:text-sm`}
            >
              <span className="chip-icon flex size-6 items-center justify-center rounded-control">
                <ProductIcon id={s.id} size={14} />
              </span>
              {s.label}
            </button>
          );
        })}
      </div>

      <Stats key={active} id={current.id} stats={current.stats} className="mt-7" />

      <div className="mt-6 overflow-hidden rounded-card">
        {screens.map((s, i) => {
          const on = i === active;
          // Initial tab is eager; above-the-fold hidden panels use fetchPriority="low" + lazy.
          const imgProps = {
            width: 2560,
            height: 1600,
            decoding: 'async' as const,
            alt: s.alt,
            loading: i === 0 ? ('eager' as const) : ('lazy' as const),
            fetchPriority: i === 0 ? undefined : ('low' as const),
          };
          return (
            <div
              key={s.id}
              role="tabpanel"
              aria-labelledby={`screen-tab-${s.id}`}
              hidden={!on}
              className={on ? 'tab-panel-in' : undefined}
            >
              <img {...imgProps} src={s.shot.light} className="block aspect-[16/10] h-auto w-full object-cover object-top dark:hidden" />
              <img {...imgProps} src={s.shot.dark} className="hidden aspect-[16/10] h-auto w-full object-cover object-top dark:block" />
            </div>
          );
        })}
      </div>

      <p className="mt-4 flex flex-wrap items-center justify-center gap-x-3 gap-y-1 text-sm text-muted">
        <span>{current.caption}</span>
        <Link href={`/${current.id}/`} className="font-medium text-[var(--accent-ink)] hover:underline">
          Explore {current.label} <span aria-hidden="true">→</span>
        </Link>
      </p>
    </div>
  );
}
