import Link from 'next/link';
import type { Metadata } from 'next';
import { Shell } from '@/components/site/Shell';
import { SearchHero } from '@/components/docs/SearchHero';
import { ProvidedSearch } from '@/components/docs/ProvidedSearch';
import { Provider } from '@/components/provider';
import { Mark } from '@/components/ui/Mark';
import { Reveal } from '@/components/ui/Reveal';
import { commonPaths, products } from '@/lib/site';

export const metadata: Metadata = {
  title: 'Noodle Docs',
  description: 'Guides for running local AI models, containers and CI jobs on your Mac with Noodle.',
  alternates: { canonical: '/docs/' },
};

const blurbs: Record<string, string> = {
  containers: 'Run your apps and Compose projects on your Mac. The docker commands you already use keep working.',
  models: 'Chat with AI models that run on your Mac, and connect your tools to them. Nothing leaves your computer.',
  runners: 'Point a GitHub Actions job at your Mac with one line. Each job gets a fresh runner that is gone when it ends.',
};

export default function DocsHome() {
  return (
    <Provider>
    <Shell searchSlot={<ProvidedSearch />}>
      <div className="shell py-16 md:py-24">
        <div className="mx-auto max-w-2xl text-center">
          <h1 className="display flex items-center justify-center gap-3 text-[clamp(2.4rem,6vw,3.6rem)]">
            <Mark size={44} />
            Noodle Docs
          </h1>
          <p className="mt-5 text-lg text-muted">Local AI, containers and CI jobs on your Mac. Start with a quickstart, or search.</p>
          <div className="mt-8">
            <SearchHero />
          </div>
        </div>

        <ul className="mx-auto mt-16 grid max-w-5xl gap-5 md:grid-cols-3">
          {products.map((p, i) => (
            <li key={p.id}>
              <Reveal delay={i * 0.06} className="h-full">
                <div className="lift spring-soft flex h-full flex-col rounded-card border border-line bg-surface p-6">
                  <h2 className="text-xl font-semibold">
                    <Link href={p.href} className="hover:underline">
                      {p.name}
                    </Link>
                  </h2>
                  <p className="mt-2 flex-1 text-sm leading-relaxed text-muted">{blurbs[p.id]}</p>
                  <ul className="mt-5 grid gap-2 border-t border-line pt-4 text-sm">
                    {p.links.map((l) => (
                      <li key={l.href}>
                        <Link href={l.href} className="flex items-center justify-between text-ink hover:text-[var(--accent-ink)]">
                          {l.label}
                          <span aria-hidden="true">→</span>
                        </Link>
                      </li>
                    ))}
                  </ul>
                </div>
              </Reveal>
            </li>
          ))}
        </ul>

        <section aria-labelledby="common-paths" className="mx-auto mt-16 max-w-5xl">
          <h2 id="common-paths" className="eyebrow">
            Common paths
          </h2>
          <ul className="mt-5 grid gap-3 sm:grid-cols-2">
            {commonPaths.map((p) => (
              <li key={p.href}>
                <Link href={p.href} className="lift spring-soft flex items-center justify-between rounded-panel border border-line bg-surface px-4 py-3.5 text-sm font-medium">
                  {p.label}
                  <span aria-hidden="true" className="text-faint">
                    →
                  </span>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      </div>
    </Shell>
    </Provider>
  );
}
