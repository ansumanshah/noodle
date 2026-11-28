import type { Metadata, Viewport } from 'next';
import { Bricolage_Grotesque, Fraunces, Geist_Mono } from 'next/font/google';
import { siteConfig } from '@/lib/site';
import './global.css';

// Self-hosted at build time by next/font, so the CSP needs no font host.
// Text: Bricolage Grotesque. Headings: Fraunces, soft and with a real italic for the accent line. Code: Geist Mono.
const sans = Bricolage_Grotesque({ subsets: ['latin'], variable: '--font-bricolage', display: 'swap' });
const mono = Geist_Mono({ subsets: ['latin'], variable: '--font-geist-mono', display: 'swap' });
const display = Fraunces({
  subsets: ['latin'],
  style: ['normal', 'italic'],
  axes: ['SOFT', 'opsz'],
  variable: '--font-fraunces',
  display: 'swap',
});

export const metadata: Metadata = {
  metadataBase: new URL(siteConfig.origin),
  title: { default: 'Noodle', template: '%s · Noodle' },
  description: 'Local AI, Docker and CI runners in one small Mac app. Free, open source, no account.',
  // The .ico (16/32/48) covers browsers and crawlers that skip SVG icons.
  icons: {
    icon: [
      { url: '/favicon.ico', sizes: '48x48' },
      { url: '/assets/favicon.svg', type: 'image/svg+xml' },
    ],
    apple: '/brand/web/apple-touch-icon.png',
  },
  openGraph: { siteName: 'Noodle', type: 'website' },
  twitter: { card: 'summary_large_image' },
  alternates: { types: { 'application/rss+xml': '/releases.xml' } },
};

export const viewport: Viewport = {
  colorScheme: 'dark light',
  themeColor: '#0c0b0d',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning className={`dark ${sans.variable} ${mono.variable} ${display.variable}`}>
      <head>
        {/* Dark is the default, with or without scripts; only a saved light choice changes it. Docs pages hand the key to next-themes. */}
        <script
          dangerouslySetInnerHTML={{
            __html:
              "(function(){var d=document.documentElement;d.classList.add('js');try{if(localStorage.getItem('theme')==='light')d.classList.remove('dark')}catch(e){}})()",
          }}
        />
      </head>
      <body className="flex min-h-screen flex-col">
        <a className="skip-link" href="#main">
          Skip to content
        </a>
        {children}
      </body>
    </html>
  );
}
