'use client';

// Flips the .dark class and remembers the choice under the same key next-themes uses on docs pages.
// The first paint is set by the inline script in the root layout.
export function ThemeToggle() {
  function toggle() {
    const root = document.documentElement;
    const dark = !root.classList.contains('dark');
    root.classList.toggle('dark', dark);
    try {
      localStorage.setItem('theme', dark ? 'dark' : 'light');
    } catch (e: unknown) {
      if (!(e instanceof Error)) throw e;
    }
  }

  return (
    <button type="button" onClick={toggle} aria-label="Toggle light and dark theme" className="spring press flex size-9 items-center justify-center rounded-panel border border-line bg-surface text-muted hover:text-ink">
      {/* The icon shows the theme a click switches to. */}
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className="dark:hidden">
        <path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z" />
      </svg>
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true" className="hidden dark:block">
        <circle cx="12" cy="12" r="4.2" />
        <path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4" />
      </svg>
    </button>
  );
}
