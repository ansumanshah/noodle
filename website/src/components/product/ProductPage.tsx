import Link from 'next/link';
import { ChatDemo } from '@/components/motion/ChatDemo';
import { JobTimeline, WhatRunsWhere } from '@/components/landing/Diagrams';
import { GithubButton } from '@/components/landing/Hero';
import { Screenshot } from '@/components/landing/Media';
import { ProductIcon } from '@/components/landing/ProductIcon';
import { DownloadButton } from '@/components/site/DownloadButton';
import { Command } from '@/components/ui/Command';
import { Stats } from '@/components/product/Stats';
import { RunnersCost } from '@/components/product/RunnersCost';
import { Reveal } from '@/components/ui/Reveal';
import { shot } from '@/lib/media';
import { pages } from '@/lib/product-pages';
import { product, type Product } from '@/lib/site';

// One page per product: promise and proof, live screen, best use cases, architecture diagram, FAQ, CTA.
export function ProductPage({ id }: { id: Product['id'] }) {
  const p = product(id);
  const c = pages[id];
  const s = shot(id);
  return (
    <div className={`tone-${id}`}>
      <div className="wash py-14 md:py-20">
        <header className="shell text-center">
          <p className="inline-flex items-center gap-2 text-sm font-semibold text-[var(--p-ink)]">
            <span className="flex size-7 items-center justify-center rounded-full bg-[var(--p)] text-[var(--paper)]">
              <ProductIcon id={id} size={15} />
            </span>
            {c.eyebrow}
          </p>
          <h1 className="display mx-auto mt-5 max-w-[16ch] text-balance text-[clamp(2.6rem,6.5vw,4.6rem)]">{c.title}</h1>
          <p className="mx-auto mt-5 max-w-[54ch] text-[1.08rem] leading-relaxed text-muted">{c.lede}</p>
          <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
            <DownloadButton />
            <GithubButton />
          </div>
          <Stats id={id} stats={c.stats} className="mt-10" />
        </header>
        <Reveal className="shell mt-12 max-w-[1080px]">
          <Screenshot shot={s} alt={c.alt} priority />
        </Reveal>
      </div>

      <section aria-labelledby="best-title" className="shell mt-20 md:mt-28">
        <Reveal className="max-w-3xl">
          <p className="eyebrow">Best for</p>
          <h2 id="best-title" className="display mt-4 text-balance text-[clamp(2rem,4.4vw,3rem)]">{c.best}</h2>
          <p className="mt-4 text-muted">{c.bestText}</p>
        </Reveal>
        <ul className="mt-10 grid grid-cols-[minmax(0,1fr)] gap-4 md:grid-cols-2">
          {c.cases.map((u, i) => (
            <Reveal key={u.title} delay={i * 0.04}>
              <li className="h-full min-w-0 rounded-card border border-line bg-raised p-6">
                <h3 className="text-lg font-semibold">{u.title}</h3>
                <p className="mt-2 text-[0.95rem] text-muted">{u.text}</p>
                {u.code ? <Command command={u.code} className="mt-4" /> : null}
              </li>
            </Reveal>
          ))}
        </ul>
      </section>

      {id === 'runners' ? <RunnersCost /> : null}

      <section aria-label="How it works" className="shell mt-20 md:mt-28">
        <Reveal>
          {id === 'models' ? <ChatDemo /> : id === 'containers' ? <WhatRunsWhere /> : <JobTimeline />}
        </Reveal>
        {id === 'containers' ? (
          <p className="mt-5 text-center text-sm">
            <Link href="/benchmarks/resources/" className="font-medium text-[var(--accent-ink)] hover:underline">
              Every number against OrbStack and Kiri, the losses too <span aria-hidden="true">→</span>
            </Link>
          </p>
        ) : null}
      </section>

      <section aria-labelledby="faq-title" className="shell mt-20 max-w-3xl md:mt-28">
        <h2 id="faq-title" className="display text-[clamp(1.8rem,4vw,2.6rem)]">Questions</h2>
        <div className="mt-6 divide-y divide-[var(--line)] border-y border-line">
          {c.faq.map((f) => (
            <details key={f.q} className="faq group py-4">
              <summary className="flex cursor-pointer list-none items-center justify-between gap-4 font-medium">
                {f.q}
                <span aria-hidden="true" className="faq-plus text-xl text-faint">+</span>
              </summary>
              <p className="faq-body mt-2 text-muted">{f.a}</p>
            </details>
          ))}
        </div>
      </section>

      <section className="shell mt-20 mb-4 text-center md:mt-28">
        <Reveal className="panel-tint rounded-card px-6 py-14 md:py-20">
          <h2 className="display mx-auto max-w-[18ch] text-[clamp(2rem,4.6vw,3.2rem)]">Try {p.name.replace('Noodle ', '')} on your Mac.</h2>
          <p className="mx-auto mt-4 max-w-[48ch] text-muted">Apple silicon, macOS 26 or later.</p>
          <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
            <DownloadButton />
            <Link href={p.links[0].href} className="spring press hover-lift inline-flex items-center gap-2 h-control rounded-panel border px-4 text-sm font-medium" style={{ borderColor: 'var(--line-strong)' }}>
              Read the quickstart
            </Link>
          </div>
        </Reveal>
      </section>
    </div>
  );
}
