import { InView } from '@/components/motion/InView';
import type { Shot } from '@/lib/media';

interface ScreenshotProps {
  shot: Shot;
  alt: string;
  priority?: boolean;
}

// Both themes ship; the site's .dark class picks one, so the image follows the theme toggle, not
// only the OS. Priority marks LCP frames eager with high fetch priority.
export function Screenshot({ shot, alt, priority }: ScreenshotProps) {
  const common = {
    width: 2560,
    height: 1600,
    decoding: 'async' as const,
    loading: priority ? ('eager' as const) : ('lazy' as const),
    fetchPriority: priority ? ('high' as const) : undefined,
  };
  return (
    <InView className="relative overflow-hidden rounded-card">
      <img {...common} src={shot.light} alt={alt} className="block aspect-[16/10] h-auto w-full object-cover object-top dark:hidden" />
      <img {...common} src={shot.dark} alt={alt} className="hidden aspect-[16/10] h-auto w-full object-cover object-top dark:block" />
    </InView>
  );
}
