import type { MetadataRoute } from 'next';
import { source } from '@/lib/source';
import { siteConfig } from '@/lib/site';

export const dynamic = 'force-static';

export default function sitemap(): MetadataRoute.Sitemap {
  const at = (path: string) => new URL(path.endsWith('/') ? path : `${path}/`, siteConfig.origin).href;
  const fixed = ['/', '/models/', '/containers/', '/runners/', '/docs/', '/benchmarks/resources/', '/releases/', '/licenses/'];
  return [...fixed, ...source.getPages().map((p) => p.url)].map((path) => ({ url: at(path) }));
}
