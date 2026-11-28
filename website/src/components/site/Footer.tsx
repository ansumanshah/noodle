import Link from 'next/link';
import { Mark } from '@/components/ui/Mark';
import { products, siteConfig } from '@/lib/site';

const cols = [
  { title: 'Products', items: products.map((p) => ({ label: p.name, href: p.href })) },
  {
    title: 'Docs',
    items: [
      { label: 'Install', href: '/docs/install/' },
      { label: 'CLI', href: '/docs/cli/' },
      { label: 'Scripts and AI tools', href: '/docs/agents/' },
      { label: 'llms.txt', href: '/llms.txt' },
      { label: 'Security', href: '/docs/security/' },
    ],
  },
  {
    title: 'Project',
    items: [
      { label: 'Benchmarks', href: '/benchmarks/resources/' },
      { label: 'Releases', href: '/releases/' },
      { label: 'RSS', href: '/releases.xml' },
      { label: 'Licences and kernel source', href: '/licenses/' },
    ],
  },
];

export function Footer() {
  return (
    <footer className="mt-24 border-t border-line">
      <div className="shell grid gap-10 py-12 md:grid-cols-[1.3fr_repeat(3,1fr)]">
        <div>
          <Link href="/" className="flex items-center gap-2 font-semibold">
            <Mark size={26} />
            {siteConfig.name}
          </Link>
          <p className="mt-3 max-w-[32ch] text-sm text-muted">Made by {siteConfig.author}. Free and open source under Apache-2.0.</p>
        </div>
        {cols.map((col) => (
          <nav key={col.title} aria-label={col.title}>
            <h2 className="eyebrow">{col.title}</h2>
            <ul className="mt-4 grid gap-2.5 text-sm">
              {col.items.map((item) => (
                <li key={item.href}>
                  <Link href={item.href} className="text-muted hover:text-ink">
                    {item.label}
                  </Link>
                </li>
              ))}
            </ul>
          </nav>
        ))}
      </div>
      <div className="shell grid gap-2 border-t border-line py-6 text-xs text-faint">
        <p>Docker is a trademark of Docker, Inc. OrbStack and other product names belong to their owners. Noodle is independent software and is not affiliated with them.</p>
        <p>The guest kernel is Linux under GPL-2.0. Matching sources, configuration and build scripts are published with each release, as described on the licences page.</p>
      </div>
    </footer>
  );
}
