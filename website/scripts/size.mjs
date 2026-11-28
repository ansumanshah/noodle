// Prints the gzip size of the JS and CSS each page loads, and fails when the landing page
// exceeds its budget. Run after `bun run build`.
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { gzipSync } from 'node:zlib';

const out = path.resolve(import.meta.dirname, '..', 'out');
const LANDING_JS_BUDGET = 150 * 1024;
const pages = ['index.html', 'docs/index.html', 'docs/containers/index.html', 'benchmarks/resources/index.html'];
const kb = (n) => `${(n / 1024).toFixed(1)} KB`;

async function assets(page) {
  const html = await readFile(path.join(out, page), 'utf8');
  const urls = new Set();
  // Count only what the HTML pulls in as scripts or stylesheets.
  // Scripts marked noModule are legacy polyfills that browsers with ES modules never fetch.
  for (const m of html.matchAll(/<script\b([^>]*)\bsrc="([^"]+)"([^>]*)>/g)) {
    if (/noModule/.test(m[1] + m[3])) continue;
    urls.add(m[2]);
  }
  for (const m of html.matchAll(/<link\b[^>]*rel="stylesheet"[^>]*href="([^"]+)"/g)) urls.add(m[1]);
  let js = 0;
  let css = 0;
  const hints = ['next-themes', 'radix', 'orama', 'lucide', 'tailwind-merge', 'cva', 'useSearchContext', 'animate', 'react-dom', 'clipboard', 'IntersectionObserver', 'sidebar', 'framer'];
  for (const url of urls) {
    const buf = await readFile(path.join(out, url));
    const gz = gzipSync(buf).length;
    if (process.argv.includes('--detail') && page === 'index.html') {
      const text = buf.toString('utf8');
      console.log(`  ${path.basename(url).padEnd(24)} ${kb(gz).padStart(9)}  ${hints.filter((h) => text.includes(h)).join(', ')}`);
    }
    if (url.endsWith('.css')) css += gz;
    else js += gz;
  }
  return { js, css, html: gzipSync(Buffer.from(html)).length };
}

let failed = false;
for (const page of pages) {
  const { js, css, html } = await assets(page);
  const label = `/${page.replace(/index\.html$/, '')}`;
  console.log(`${label.padEnd(26)} js ${kb(js).padStart(9)}  css ${kb(css).padStart(8)}  html ${kb(html).padStart(8)} (gzip)`);
  if (page === 'index.html' && js > LANDING_JS_BUDGET) {
    failed = true;
    console.error(`landing JS ${kb(js)} is over the ${kb(LANDING_JS_BUDGET)} budget`);
  }
}
for (const file of ['media/containers-light.webp', 'api/search']) {
  console.log(`${`/${file}`.padEnd(26)} ${kb((await stat(path.join(out, file))).size)} on disk`);
}
process.exit(failed ? 1 : 0);
