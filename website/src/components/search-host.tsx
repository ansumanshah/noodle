'use client';
import { useEffect } from 'react';
import { RootProvider } from 'fumadocs-ui/provider/next';
import { useSearchContext } from 'fumadocs-ui/contexts/search';
import SearchDialog from '@/components/search';

function Opener({ signal }: { signal: number }) {
  const { setOpenSearch } = useSearchContext();
  useEffect(() => {
    setOpenSearch(true);
  }, [signal, setOpenSearch]);
  return null;
}

// Loaded on first use from marketing pages: a full search provider (theme handling off, the page
// owns it) that opens as soon as it mounts and whenever `signal` changes. Cmd-K is handled by the provider after that.
export default function SearchHost({ signal }: { signal: number }) {
  return (
    <RootProvider theme={{ enabled: false }} search={{ SearchDialog, preload: false }}>
      <Opener signal={signal} />
    </RootProvider>
  );
}
