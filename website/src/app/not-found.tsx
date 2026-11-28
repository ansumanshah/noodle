import Link from 'next/link';
import { Shell } from '@/components/site/Shell';

export default function NotFound() {
  return (
    <Shell>
      <div className="shell py-28 text-center">
        <p className="eyebrow">404</p>
        <h1 className="display mt-4 text-[clamp(2.2rem,5vw,3.4rem)]">That page is not here.</h1>
        <p className="mt-4 text-muted">It may have moved. The docs search finds most things.</p>
        <p className="mt-6 flex justify-center gap-5 text-sm font-medium text-[var(--accent-ink)]">
          <Link href="/docs/" className="hover:underline">Open the docs</Link>
          <Link href="/" className="hover:underline">Go home</Link>
        </p>
      </div>
    </Shell>
  );
}
