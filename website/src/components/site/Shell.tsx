import type { ReactNode } from 'react';
import { Header } from './Header';
import { Footer } from './Footer';

// Header, main landmark and footer for every page outside the docs sidebar layout.
export function Shell({ children, searchSlot }: { children: ReactNode; searchSlot?: ReactNode }) {
  return (
    <>
      <Header searchSlot={searchSlot} />
      <main id="main" className="flex-1">
        {children}
      </main>
      <Footer />
    </>
  );
}
