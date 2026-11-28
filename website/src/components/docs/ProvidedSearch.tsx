'use client';
import { useSearchContext } from 'fumadocs-ui/contexts/search';
import { SearchLabel, searchButtonClass } from '@/components/site/search-button';

// For pages inside the docs search provider: opens its dialog instead of mounting a second one.
export function ProvidedSearch() {
  const { setOpenSearch } = useSearchContext();
  return (
    <button type="button" className={searchButtonClass} aria-label="Search docs" onClick={() => setOpenSearch(true)}>
      <SearchLabel />
    </button>
  );
}
