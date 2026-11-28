import { existsSync } from 'node:fs';
import { join } from 'node:path';

// Build-time only. A missing capture fails the export instead of shipping a stale stand-in.
const has = (path: string) => existsSync(join(process.cwd(), 'public', path));

export interface Shot {
  light: string;
  dark: string;
}

export function shot(name: string): Shot {
  const light = `/media/${name}-light.webp`;
  const dark = `/media/${name}-dark.webp`;
  if (!has(light) || !has(dark)) throw new Error(`missing screenshot: public${light} or public${dark}`);
  return { light, dark };
}
