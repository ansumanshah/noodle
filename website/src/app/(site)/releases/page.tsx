import Link from 'next/link';
import type { Metadata } from 'next';
import { DownloadButton } from '@/components/site/DownloadButton';
import { Mark } from '@/components/ui/Mark';
import { siteConfig } from '@/lib/site';

export const metadata: Metadata = {
  title: 'Releases',
  description: 'Release notes and Mac downloads for Noodle.',
  alternates: { canonical: '/releases/' },
};

const changes = [
  { term: 'Noodle Models', text: 'Local models with an OpenAI-compatible URL for your tools.' },
  { term: 'Noodle Containers', text: 'Your Docker CLI, with Compose projects grouped in the Mac app.' },
  { term: 'Noodle Runners', text: 'GitHub Actions jobs on your Mac, each in a fresh runner.' },
  { term: 'VM status', text: 'Whether Linux is running, its memory, and where your Docker CLI points.' },
];

export default function Releases() {
  const { version: v, url, notes } = siteConfig.release;
  return (
    <div className="shell py-14 md:py-20">
      <header className="flex flex-wrap items-center justify-between gap-6">
        <div className="max-w-xl">
          <p className="eyebrow">Noodle for Mac</p>
          <h1 className="display mt-4 text-[clamp(2.2rem,5vw,3.4rem)]">Release notes</h1>
          <p className="mt-4 text-muted">What each version contains, and where to download it.</p>
          <p className="mt-4 flex gap-5 text-sm font-medium text-[var(--accent-ink)]">
            <Link href="/docs/install/" className="hover:underline">Install guide</Link>
            <a href={notes} className="hover:underline">GitHub release</a>
            <a href="/releases.xml" className="hover:underline">RSS feed</a>
          </p>
        </div>
        <div className="flex items-center gap-4 rounded-card border border-line bg-surface p-5">
          <Mark size={52} />
          <div>
            <p className="eyebrow">Latest</p>
            <p className="mt-1 font-mono text-4xl tracking-tight">{v}</p>
          </div>
        </div>
      </header>

      <div className="mt-14 grid gap-10 md:grid-cols-[1.6fr_1fr]">
        <article id={`v${v.replaceAll('.', '-')}`} className="border-l-2 border-accent pl-5">
          <p className="eyebrow">Latest release</p>
          <h2 className="mt-3 text-2xl font-semibold tracking-tight">Noodle {v}</h2>
          <dl className="mt-5">
            {changes.map((c) => (
              <div key={c.term} className="grid gap-1 border-t border-line py-4 sm:grid-cols-[10rem_1fr] sm:gap-5">
                <dt className="font-semibold">{c.term}</dt>
                <dd className="text-muted">{c.text}</dd>
              </div>
            ))}
          </dl>
          <p className="mt-2 text-sm"><Link href="/docs/models/quickstart/" className="font-medium text-[var(--accent-ink)] hover:underline">Quickstart</Link></p>
        </article>
        <aside className="h-fit rounded-card border border-line bg-surface p-6">
          <p className="eyebrow">Noodle {v}</p>
          <h2 className="mt-3 text-xl font-semibold">Download for Mac</h2>
          <p className="mt-1 text-sm text-muted">Apple silicon, macOS 26 or later</p>
          <DownloadButton className="mt-5" />
          <p className="mt-3 font-mono text-xs text-faint">{url.split('/').pop()}</p>
        </aside>
      </div>
    </div>
  );
}
