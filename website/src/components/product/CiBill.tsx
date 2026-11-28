'use client';
import { useState } from 'react';
import { macMini, minutePresets, money, paybackDays, rates, type Platform } from '@/lib/ci-prices';

interface ChoiceProps<T extends string | number> {
  name: string;
  label: string;
  value: T;
  options: { id: T; label: string }[];
  onChange: (v: T) => void;
}

// Native radios: one tab stop per group, arrow keys move inside it, the label names the group for screen readers.
function Choice<T extends string | number>({ name, label, value, options, onChange }: ChoiceProps<T>) {
  return (
    <fieldset className="min-w-0">
      <legend className="eyebrow mb-2">{label}</legend>
      <div className="flex flex-wrap gap-[var(--spacing-gap)]">
        {options.map((o) => (
          <label
            key={String(o.id)}
            className="spring press inline-flex h-control cursor-pointer items-center rounded-panel border border-line px-4 text-sm font-medium text-muted has-[:checked]:border-[var(--p)] has-[:checked]:bg-[var(--p)] has-[:checked]:text-[var(--paper)] has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2 has-[:focus-visible]:outline-[var(--accent)]"
          >
            <input type="radio" name={name} className="sr-only" checked={value === o.id} onChange={() => onChange(o.id)} />
            {o.label}
          </label>
        ))}
      </div>
    </fieldset>
  );
}

const platforms: { id: Platform; label: string }[] = [
  { id: 'macos', label: 'macOS' },
  { id: 'linux', label: 'Linux' },
];
const sources = [...new Set(Object.values(rates).flat().map((r) => r.url))];

export function CiBill() {
  const [platform, setPlatform] = useState<Platform>('macos');
  const [minutes, setMinutes] = useState(30_000);
  const list = rates[platform];
  const days = paybackDays(minutes, list[0].perMinute);
  const cards = [
    ...list.map((r) => ({ k: r.provider, v: money(r.perMinute * minutes), s: `$${r.perMinute} a minute, ${r.size}`, own: false })),
    { k: 'Your Mac', v: '$0', s: 'no per-minute rate; the Mac and its power are yours', own: true },
  ];

  return (
    <div className="rounded-card border border-line bg-raised p-6">
      <div className="flex flex-wrap gap-x-10 gap-y-5">
        <Choice name="platform" label="Jobs run on" value={platform} options={platforms} onChange={setPlatform} />
        <Choice name="minutes" label="Minutes a month" value={minutes} options={minutePresets.map((m) => ({ id: m, label: m.toLocaleString('en-US') }))} onChange={setMinutes} />
      </div>
      <div role="status" aria-live="polite" className="mt-6">
        <ul className="grid grid-cols-[minmax(0,1fr)] gap-[var(--spacing-gap)] sm:grid-cols-3">
          {cards.map((c) => (
            <li key={c.k} className={`rounded-panel border p-[var(--spacing-inset)] ${c.own ? 'border-[var(--p)] bg-[var(--p-soft)]' : 'border-line'}`}>
              <p className="text-sm text-muted">{c.k}, a month</p>
              <p className={`display mt-1 text-[2rem] leading-none tabular-nums ${c.own ? 'text-[var(--p-ink)]' : ''}`}>{c.v}</p>
              <p className="mt-2 text-xs text-faint">{c.s}</p>
            </li>
          ))}
        </ul>
        <p className="mt-4 text-[0.95rem] text-ink">
          At {minutes.toLocaleString('en-US')} {platform === 'macos' ? 'macOS' : 'Linux'} minutes a month, GitHub’s rate adds up to the price of a Mac mini (from {money(macMini.price)}) in {days} {days === 1 ? 'day' : 'days'}.
        </p>
      </div>
      <p className="mt-4 text-xs leading-relaxed text-faint">
        Published pay-as-you-go rates (
        {sources.map((u, i) => (
          <span key={u}>
            {i ? ', ' : ''}
            <a href={u} className="underline hover:text-ink">{new URL(u).hostname}</a>
          </span>
        ))}
        ) and <a href={macMini.url} className="underline hover:text-ink">apple.com</a> for the Mac mini. Free allowances, volume discounts and electricity are left out.
      </p>
      <p className="mt-2 text-xs leading-relaxed text-faint">Hosted runners still win on a clean VM per job, no machine to keep on, and scale past one Mac.</p>
    </div>
  );
}
