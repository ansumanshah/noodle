import type { Metadata } from 'next';
import { ProductPage } from '@/components/product/ProductPage';
import { pages } from '@/lib/product-pages';

export const metadata: Metadata = {
  title: 'Runners',
  description: pages.runners.lede,
  alternates: { canonical: '/runners/' },
};

export default function Page() {
  return <ProductPage id="runners" />;
}
