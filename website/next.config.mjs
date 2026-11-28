import { createMDX } from 'fumadocs-mdx/next';

const withMDX = createMDX();

// Static export for Cloudflare Pages. Trailing slashes keep the /docs/<page>/ URLs of the Astro site.
/** @type {import('next').NextConfig} */
const config = {
  output: 'export',
  trailingSlash: true,
  reactStrictMode: true,
  images: { unoptimized: true },
  poweredByHeader: false,
};

export default withMDX(config);
