export const searchButtonClass = 'spring press flex h-9 items-center gap-2 rounded-panel border border-line bg-surface px-2.5 text-sm text-muted hover:text-ink';

export function SearchLabel() {
  return (
    <>
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
        <circle cx="11" cy="11" r="7" />
        <path d="M20 20l-3.5-3.5" />
      </svg>
      <span className="hidden sm:inline">Search</span>
      <kbd className="hidden rounded border border-line px-1.5 font-sans text-[0.7rem] sm:inline">⌘K</kbd>
    </>
  );
}
