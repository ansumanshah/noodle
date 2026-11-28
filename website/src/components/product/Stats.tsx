'use client';
import { useState } from 'react';
import type { Stat } from '@/lib/product-pages';
import type { Product } from '@/lib/site';

interface StatsProps {
  id: Product['id'];
  stats: Stat[];
  className?: string;
}

// Deterministic two-column benchmark/feature stats. When alternatives exist, readers pick which
// engine comparison to inspect rather than fighting an auto-advance timer.
export function Stats({ id, stats, className = '' }: StatsProps) {
  const sets = stats.map((s) => [s, ...(s.alts ?? [])]);
  const n = Math.min(...sets.map((s) => s.length));
  const [at, setAt] = useState(0);
  const index = at % n;
  const shown = sets.map((s) => s[index]);
  const bars = shown.every((s) => s.bar);
  const choices = n > 1 ? sets[0].slice(0, n).map((s) => s.bar?.name ?? s.label) : [];

  return (
    <div className={`tone-${id} ${className}`}>
      {choices.length > 1 ? (
        <div className="mb-4 flex flex-wrap items-center justify-center gap-1.5" role="group" aria-label="Compare engine">
          <span className="mr-1 text-xs text-faint">Compare vs</span>
          {choices.map((name, i) => {
            const on = i === index;
            return (
              <button
                key={name}
                type="button"
                aria-pressed={on}
                onClick={() => setAt(i)}
                className={`spring press inline-flex h-chip items-center rounded-panel border px-2.5 text-xs font-medium ${
                  on
                    ? 'border-[var(--p)] bg-[var(--p-soft)] text-[var(--p-ink)]'
                    : 'border-line bg-surface text-muted hover:text-ink'
                }`}
              >
                {name}
              </button>
            );
          })}
        </div>
      ) : null}
      <dl className="mx-auto grid max-w-3xl grid-cols-1 text-left sm:grid-cols-2 sm:grid-rows-[auto_auto_auto_auto]">
        {shown.map((st, i) => (
          <One key={`${i}-${index}`} stat={st} index={i} bars={bars} />
        ))}
      </dl>
    </div>
  );
}

interface OneProps {
  stat: Stat;
  index: number;
  bars: boolean;
}

function One({ stat: st, index: i, bars }: OneProps) {
  const max = st.bar ? Math.max(st.bar.us, st.bar.them) : 1;
  return (
    <div className="grid content-start px-6 py-3 sm:row-span-4 sm:grid-rows-subgrid sm:[&+&]:border-l sm:[&+&]:border-line">
      <dd className="display text-[clamp(2.4rem,5vw,3.2rem)] leading-[0.95] text-[var(--p-ink)] tabular-nums">{st.value}</dd>
      <dt className="mt-2 text-[0.98rem] leading-snug text-ink">{st.label}</dt>
      {bars && st.bar ? (
        <dd className="mt-3 grid gap-1.5" aria-label={`Noodle ${st.bar.us}, ${st.bar.name} ${st.bar.them}, lower is better`}>
          {[
            { n: 'Noodle', v: st.bar.us, on: true },
            { n: st.bar.name, v: st.bar.them, on: false },
          ].map((r) => (
            <span key={r.n} className="grid grid-cols-[96px_1fr] items-center gap-2 text-[0.7rem] text-faint tabular-nums">
              {r.n}
              <span className="h-1.5 overflow-hidden rounded-full bg-surface">
                <span
                  className="stat-bar block h-full origin-left rounded-full"
                  style={{ transform: `scaleX(${Math.max(r.v / max, 0.04)})`, background: r.on ? 'var(--p)' : 'var(--faint)', animationDelay: `${120 + i * 90}ms` }}
                />
              </span>
            </span>
          ))}
        </dd>
      ) : (
        <span aria-hidden />
      )}
      <dd className="mt-3 text-[0.68rem] font-medium tracking-[0.06em] text-faint uppercase">{st.source}</dd>
    </div>
  );
}
