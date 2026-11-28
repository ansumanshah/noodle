'use client';
import { useSearchContext } from 'fumadocs-ui/contexts/search';

// A search field that opens the Cmd-K dialog. Typing is handled by the dialog, so there is one search UI.
export function SearchHero() {
  const { setOpenSearch } = useSearchContext();
  return (
    <button
      type="button"
      onClick={() => setOpenSearch(true)}
      aria-label="Search the docs"
      className="spring press mx-auto flex w-full max-w-xl items-center gap-3 rounded-card border border-line bg-raised px-4 py-3.5 text-left text-muted shadow-[var(--shadow)] hover:-translate-y-0.5"
    >
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
        <circle cx="11" cy="11" r="7" />
        <path d="M20 20l-3.5-3.5" />
      </svg>
      <span className="flex-1">Search Noodle docs</span>
      <kbd className="rounded-control border border-line px-2 py-0.5 font-sans text-xs">⌘K</kbd>
    </button>
  );
}
