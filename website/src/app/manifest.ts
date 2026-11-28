import type { MetadataRoute } from 'next';

export const dynamic = 'force-static';

// Install metadata for browsers and Android. Icons come from public/brand (GenerateAppIcon.swift --brand).
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: 'Noodle',
    short_name: 'Noodle',
    description: 'Local AI, Docker and CI runners. One small Mac app.',
    start_url: '/',
    display: 'browser',
    background_color: '#0c0b0d',
    theme_color: '#951360',
    icons: [
      { src: '/brand/web/icon-192.png', sizes: '192x192', type: 'image/png' },
      { src: '/brand/web/icon-512.png', sizes: '512x512', type: 'image/png' },
      { src: '/brand/web/icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
    ],
  };
}
