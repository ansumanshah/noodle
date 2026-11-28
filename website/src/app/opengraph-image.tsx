import { ogImage, ogSize } from '@/lib/og';

export const dynamic = 'force-static';
export const alt = 'Noodle: Models, Containers and Runners in one small Mac app.';
export const size = ogSize;
export const contentType = 'image/png';

export default function Image() {
  return ogImage();
}
