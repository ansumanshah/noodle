import type { Product } from '@/lib/site';

export const productIconPaths: Record<Product['id'], string> = {
  // A crate.
  containers: 'M12 3l8 4.5v9L12 21l-8-4.5v-9L12 3zM4 7.5l8 4.5 8-4.5M12 12v9',
  // A spark.
  models: 'M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9L12 3zM18.5 15.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8.8-2.2z',
  // A loop with a play mark: a job that starts, runs and ends.
  runners: 'M20 12a8 8 0 1 1-2.34-5.66M20 4v4h-4M10 9l5 3-5 3V9z',
};

interface ProductIconProps {
  id: Product['id'];
  size?: number;
}

// Drawn in the product's colour via currentColor; set the colour on the parent.
export function ProductIcon({ id, size = 18 }: ProductIconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={productIconPaths[id]} />
    </svg>
  );
}
