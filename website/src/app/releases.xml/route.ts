import { siteConfig } from '@/lib/site';

export const dynamic = 'force-static';

export function GET() {
  const { version, date, notes } = siteConfig.release;
  const releases = new URL('/releases/', siteConfig.origin).href;
  const feed = new URL('/releases.xml', siteConfig.origin).href;
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
  <channel>
    <title>Noodle releases</title>
    <link>${releases}</link>
    <description>Release notes for Noodle.</description>
    <atom:link href="${feed}" rel="self" type="application/rss+xml" />
    <item>
      <title>Noodle ${version}</title>
      <link>${notes}</link>
      <guid>${notes}</guid>
      <pubDate>${new Date(`${date}T00:00:00Z`).toUTCString()}</pubDate>
      <description>The first public release: Noodle Containers, Noodle Models and Noodle Runners in one Mac app.</description>
    </item>
  </channel>
</rss>`;
  return new Response(body, { headers: { 'Content-Type': 'application/rss+xml; charset=utf-8' } });
}
