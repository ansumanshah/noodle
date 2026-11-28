import type { Metadata } from 'next';
import { ProductPage } from '@/components/product/ProductPage';
import { pages } from '@/lib/product-pages';

export const metadata: Metadata = {
  title: 'Models',
  description: pages.models.lede,
  alternates: { canonical: '/models/' },
};

export default function Page() {
  return <ProductPage id="models" />;
}
