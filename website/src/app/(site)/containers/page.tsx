import type { Metadata } from 'next';
import { ProductPage } from '@/components/product/ProductPage';
import { pages } from '@/lib/product-pages';

export const metadata: Metadata = {
  title: 'Containers',
  description: pages.containers.lede,
  alternates: { canonical: '/containers/' },
};

export default function Page() {
  return <ProductPage id="containers" />;
}
