'use client';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { lazy, Suspense, useEffect, useState, type ReactNode } from 'react';
import { Mark } from '@/components/ui/Mark';
import { ThemeToggle } from '@/components/site/ThemeToggle';
import { SearchLabel, searchButtonClass } from '@/components/site/search-button';
import { siteConfig } from '@/lib/site';

const links = [
  { label: 'Docs', href: '/docs/' },
  { label: 'Models', href: '/models/' },
  { label: 'Containers', href: '/containers/' },
  { label: 'Runners', href: '/runners/' },
  { label: 'Benchmarks', href: '/benchmarks/resources/' },
];

// The search provider, dialog and index load the first time search opens.
const SearchHost = lazy(() => import('@/components/search-host'));

// Marketing pages carry no search provider. Until one loads, this owns the button and the Cmd-K
// shortcut. Once loaded, the provider handles Cmd-K itself, so the listener steps aside.
function StandaloneSearch() {
  const [signal, setSignal] = useState(0);

  useEffect(() => {
    if (signal > 0) return;
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        setSignal(1);
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [signal]);

  return (
    <>
      <button type="button" className={searchButtonClass} aria-label="Search docs" onClick={() => setSignal((s) => s + 1)}>
        <SearchLabel />
      </button>
      {signal > 0 ? (
        <Suspense fallback={null}>
          <SearchHost signal={signal} />
        </Suspense>
      ) : null}
    </>
  );
}

// searchSlot replaces the standalone search on pages that already sit inside the docs search provider.
export function Header({ searchSlot }: { searchSlot?: ReactNode }) {
  const path = usePathname();
  const [menuOpen, setMenuOpen] = useState(false);
  const active = (href: string) => path.startsWith(href.split('/').slice(0, 2).join('/') + '/');

  useEffect(() => {
    setMenuOpen(false);
  }, [path]);

  useEffect(() => {
    if (!menuOpen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setMenuOpen(false);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [menuOpen]);

  return (
    <header className="sticky top-0 z-40 border-b border-line bg-paper/85 backdrop-blur-md">
      <div className="shell flex h-14 items-center gap-5">
        <Link href="/" className="flex items-center gap-2 font-semibold tracking-tight">
          <Mark size={26} />
          {siteConfig.name}
        </Link>
        <nav aria-label="Main" className="hidden gap-5 text-sm text-muted md:flex">
          {links.map((l) => {
            const isCurrent = active(l.href);
            return (
              <Link
                key={l.href}
                href={l.href}
                aria-current={isCurrent ? 'page' : undefined}
                className={isCurrent ? 'font-medium text-ink' : 'hover:text-ink'}
              >
                {l.label}
              </Link>
            );
          })}
        </nav>
        <div className="ml-auto flex items-center gap-2">
          {searchSlot ?? <StandaloneSearch />}
          <a
            href={`https://github.com/${siteConfig.repo}`}
            aria-label="Noodle on GitHub"
            className="spring press flex size-9 items-center justify-center rounded-panel text-muted hover:text-ink"
          >
            <svg width="18" height="18" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
              <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0016 8c0-4.42-3.58-8-8-8z" />
            </svg>
          </a>
          <ThemeToggle />
          <a href={siteConfig.release.url} className="spring press hidden rounded-panel bg-ink px-3.5 py-2 text-sm font-medium text-paper sm:inline-flex">
            Download
          </a>
          <button
            type="button"
            aria-label={menuOpen ? 'Close navigation menu' : 'Open navigation menu'}
            aria-expanded={menuOpen}
            aria-controls="mobile-nav"
            onClick={() => setMenuOpen((o) => !o)}
            className="spring press flex size-9 items-center justify-center rounded-panel border border-line bg-surface text-muted hover:text-ink md:hidden"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true">
              {menuOpen ? <path d="M6 6l12 12M18 6L6 18" /> : <path d="M4 7h16M4 12h16M4 17h16" />}
            </svg>
          </button>
        </div>
      </div>
      {menuOpen ? (
        <nav id="mobile-nav" aria-label="Mobile" className="shell grid gap-1 border-t border-line py-3 text-sm md:hidden">
          {links.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              onClick={() => setMenuOpen(false)}
              aria-current={active(l.href) ? 'page' : undefined}
              className={`rounded-control px-2 py-2 ${active(l.href) ? 'bg-surface font-medium text-ink' : 'text-muted hover:text-ink'}`}
            >
              {l.label}
            </Link>
          ))}
          <Link
            href="/releases/"
            onClick={() => setMenuOpen(false)}
            aria-current={active('/releases/') ? 'page' : undefined}
            className={`rounded-control px-2 py-2 ${active('/releases/') ? 'bg-surface font-medium text-ink' : 'text-muted hover:text-ink'}`}
          >
            Releases
          </Link>
          <a
            href={siteConfig.release.url}
            className="mt-1 inline-flex h-control items-center justify-center rounded-panel bg-ink px-4 text-sm font-medium text-paper sm:hidden"
          >
            Download for Mac
          </a>
        </nav>
      ) : null}
    </header>
  );
}
