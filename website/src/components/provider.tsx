'use client';
import { RootProvider } from 'fumadocs-ui/provider/next';
import { lazy, type ReactNode } from 'react';

// The dialog and its search index load on first open, not with the page.
const SearchDialog = lazy(() => import('@/components/search'));

export function Provider({ children }: { children: ReactNode }) {
  return <RootProvider theme={{ defaultTheme: 'dark', enableSystem: false }} search={{ SearchDialog, preload: false }}>{children}</RootProvider>;
}
