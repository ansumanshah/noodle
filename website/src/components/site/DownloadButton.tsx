import { siteConfig } from '@/lib/site';

// The DMG on the GitHub release.
export function DownloadButton({ className = '' }: { className?: string }) {
  return (
    <a
      href={siteConfig.release.url}
      className={`spring press hover-lift inline-flex items-center gap-2 h-control rounded-panel bg-ink px-4 text-sm font-medium text-paper ${className}`}
    >
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M12 4v11M7 11l5 5 5-5M5 20h14" />
      </svg>
      Download for Mac
    </a>
  );
}
