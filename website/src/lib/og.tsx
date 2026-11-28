import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { ImageResponse } from 'next/og';
import { productIconPaths } from '@/components/landing/ProductIcon';
import { products, type Product } from './site';

// Share cards, rendered once at build time by Next's opengraph-image convention.
// Colours are the light-theme tokens in global.css.
export const ogSize = { width: 1200, height: 630 };
const tone: Record<Product['id'], { p: string; soft: string; ink: string }> = {
  models: { p: '#951360', soft: '#fbe8f2', ink: '#7f0f52' },
  containers: { p: '#0f7c99', soft: '#d4eef4', ink: '#0a5b70' },
  runners: { p: '#2f8a4c', soft: '#d9efdf', ink: '#1f6636' },
};
const paper = '#fbfbfc', ink = '#16151c', muted = '#5d5a66', berry = '#951360';

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
                  background: focus ? (on ? paper : 'rgba(255,255,255,0.45)') : tone[p.id].soft,
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
