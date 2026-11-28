// Runs after `next build`. Static export lands in out/.
//   1. Adds a hash-based <meta> Content-Security-Policy to every HTML page (see _headers).
//   2. Copies _headers and _redirects for Cloudflare Pages.
//   3. Writes <page>.md next to each docs page so /docs/<page>.md also serves plain Markdown.
import { createHash } from 'node:crypto';
import { cp, readdir, readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const out = path.join(root, 'out');

const files = (await readdir(out, { recursive: true })).filter((f) => f.endsWith('.html'));
let hashes = 0;
const maxHashes = new Map();

for (const file of files) {
  const full = path.join(out, file);
  let html = await readFile(full, 'utf8');
  const found = new Set();
  for (const [, attrs, body] of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
    if (/\bsrc=/.test(attrs) || !body) continue;
    if (/type="application\/(ld\+)?json"/.test(attrs)) continue;
    found.add(`'sha256-${createHash('sha256').update(body).digest('base64')}'`);
  }
  hashes += found.size;
  maxHashes.set(file, found.size);
  const policy = `script-src 'self' ${[...found].sort().join(' ')}`.trim();
  const meta = `<meta http-equiv="Content-Security-Policy" content="${policy}"/>`;
  // The meta tag must precede every script it governs.
  html = html.replace(/<head>/, `<head>${meta}`);
  await writeFile(full, html);
}

await cp(path.join(root, '_headers'), path.join(out, '_headers'));
await cp(path.join(root, '_redirects'), path.join(out, '_redirects'));

// Plain Markdown twins of the docs pages, from the MDX sources minus frontmatter.
const docsDir = path.join(root, 'content/docs');
let twins = 0;
for (const rel of (await readdir(docsDir, { recursive: true })).filter((f) => f.endsWith('.mdx'))) {
  const slug = rel
    .replace(/\.mdx$/, '')
    .split(path.sep)
    .filter((s) => !/^\(.*\)$/.test(s))
    .join('/');
  const target = slug.endsWith('index') ? slug.slice(0, -'index'.length).replace(/\/$/, '') || 'index' : slug;
  const source = await readFile(path.join(docsDir, rel), 'utf8');
  const [, front, body] = source.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  const title = front.match(/^title:\s*"?(.*?)"?\s*$/m)?.[1] ?? target;
  const dest = path.join(out, 'docs', `${target}.md`);
  await mkdir(path.dirname(dest), { recursive: true });
  await writeFile(dest, `# ${title}\n${body}`);
  twins += 1;
}

console.log(`postbuild: ${files.length} pages, ${hashes} inline script hashes, ${twins} markdown twins`);
