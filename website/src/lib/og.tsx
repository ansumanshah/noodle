import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { ImageResponse } from 'next/og';
import { productIconPaths } from '@/components/landing/ProductIcon';
import { products, type Product } from './site';

// Share cards, rendered once at build time by Next's opengraph-image convention.
// Colours are the dark-theme tokens in global.css.
export const ogSize = { width: 1200, height: 630 };
const tone: Record<Product['id'], { p: string; soft: string; ink: string }> = {
  models: { p: '#f5c2e7', soft: '#4b4048', ink: '#f8d1ed' },
  containers: { p: '#89dceb', soft: '#334549', ink: '#a6e5f0' },
  runners: { p: '#a6e3a1', soft: '#3a4738', ink: '#bceab8' },
};
const paper = '#0c0b0d', ink = '#f4f2f5', muted = '#a29ca8', berry = '#f5c2e7';

interface IconProps {
  id: Product['id'];
  size: number;
  color: string;
}

function Icon({ id, size, color }: IconProps) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      <path d={productIconPaths[id]} />
    </svg>
  );
}

/** No mode: the site card with all three modes. A mode: that mode's card, the other two shown small. */
export async function ogImage(mode?: Product['id']) {
  const mark = `data:image/svg+xml;base64,${(await readFile(join(process.cwd(), 'public/assets/favicon.svg'))).toString('base64')}`;
  const focus = mode ? products.find((p) => p.id === mode)! : null;
  const title = focus ? focus.tagline : 'Local AI, Docker and CI runners. One small Mac app.';
  return new ImageResponse(
    (
      <div style={{ width: '100%', height: '100%', display: 'flex', flexDirection: 'column', padding: 72, background: focus ? tone[focus.id].soft : paper, color: ink }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 18 }}>
          <img src={mark} width={64} height={64} alt="" />
          <div style={{ display: 'flex', fontSize: 34, fontWeight: 600, letterSpacing: -0.5 }}>{focus ? focus.name : 'Noodle'}</div>
          {focus ? (
            <div style={{ display: 'flex', marginLeft: 'auto', width: 84, height: 84, borderRadius: 24, background: paper, alignItems: 'center', justifyContent: 'center' }}>
              <Icon id={focus.id} size={52} color={tone[focus.id].p} />
            </div>
          ) : null}
        </div>
        <div style={{ display: 'flex', marginTop: focus ? 64 : 48, fontSize: focus ? 60 : 64, lineHeight: 1.08, letterSpacing: -1.5, maxWidth: 1000 }}>{title}</div>
        <div style={{ display: 'flex', marginTop: 'auto', gap: 20 }}>
          {products.map((p) => {
            const on = !focus || focus.id === p.id;
            return (
              <div
                key={p.id}
                style={{
                  display: 'flex', flex: 1, alignItems: 'center', gap: 14, padding: focus ? '18px 22px' : '24px 26px', borderRadius: 24,
                  background: focus ? (on ? paper : 'rgba(12,11,13,0.45)') : tone[p.id].soft,
                  color: on ? tone[p.id].ink : muted,
                }}
              >
                <Icon id={p.id} size={focus ? 30 : 38} color={on ? tone[p.id].p : muted} />
                <div style={{ display: 'flex', fontSize: focus ? 26 : 30, fontWeight: 600 }}>{p.name.replace('Noodle ', '')}</div>
              </div>
            );
          })}
        </div>
        <div style={{ display: 'flex', marginTop: 24, fontSize: 22, color: muted }}>
          <span style={{ color: berry, fontWeight: 600, marginRight: 10 }}>getnoodle.dev</span> Free, open source, no account. Apple silicon Macs.
        </div>
      </div>
    ),
    ogSize,
  );
}
