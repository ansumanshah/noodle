import { ogImage, ogSize } from '@/lib/og';
import { product } from '@/lib/site';

export const dynamic = 'force-static';
export const alt = product('runners').tagline;
export const size = ogSize;
export const contentType = 'image/png';

export default function Image() {
  return ogImage('runners');
}
