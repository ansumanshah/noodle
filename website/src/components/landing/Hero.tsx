import Link from 'next/link';
import { AgentSetupButton } from '@/components/site/AgentSetupButton';
import { Command } from '@/components/ui/Command';
import { DownloadButton } from '@/components/site/DownloadButton';
import { Reveal } from '@/components/ui/Reveal';
import { shot } from '@/lib/media';
import { pages } from '@/lib/product-pages';
import { product, siteConfig } from '@/lib/site';
import { HeroScreens, type HeroScreen } from './HeroScreens';

const worksWith = [
  'GGUF and MLX models',
  'OpenAI-style API',
  'docker',
  'GitHub Actions',
];

export function GithubButton() {
  return (
    <a
      href={`https://github.com/${siteConfig.repo}`}
      className="spring press hover-lift inline-flex items-center gap-2 h-control rounded-panel border px-4 text-sm font-medium"
      style={{ borderColor: 'var(--line-strong)' }}
    >
      <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
        <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0016 8c0-4.42-3.58-8-8-8z" />
      </svg>
      View on GitHub
    </a>
  );
}

export function Hero() {
  const screens: HeroScreen[] = (['models', 'containers', 'runners'] as const).map((id) => ({
    id,
    label: product(id).name.replace('Noodle ', ''),
    caption: pages[id].caption,
    alt: pages[id].alt,
    stats: pages[id].stats,
    shot: shot(id),
  }));
  return (
    <>
      <div className="hero-art">
        {(['dark', 'light'] as const).map((theme) => {
          const base = theme === 'light' ? '/media/hero-art-light' : '/media/hero-art';
          return (
            <img
              key={theme}
              src={`${base}.webp`}
              srcSet={`${base}-1200.webp 1200w, ${base}.webp 2400w`}
              sizes="(min-width: 1100px) 72vw, 100vw"
              alt=""
              loading="lazy"
              className={`hero-art-img hero-art-${theme}`}
            />
          );
        })}
        <section className="shell relative pt-12 pb-16 text-center md:pt-20 md:pb-24 md:text-left" aria-labelledby="hero-title">
          <div className="md:max-w-[36rem]">
            <p className="text-xs font-medium text-muted">
              <Link href="/releases/" className="inline-flex items-center gap-1.5 hover:text-ink">
                Noodle {siteConfig.release.version} beta · Apache-2.0 <span aria-hidden="true">→</span>
              </Link>
            </p>
            <h1 id="hero-title" className="display mx-auto mt-3 max-w-[20ch] text-balance text-[clamp(2.4rem,5vw,4rem)] md:mx-0">
              Run AI on your Mac. <br className="max-sm:hidden" />
              <em>Pick a model, press Run.</em>
            </h1>
            <p className="mx-auto mt-5 max-w-[48ch] text-[1.06rem] leading-relaxed text-muted md:mx-0">
              Chat with a model that lives on your Mac. After the download it works with Wi-Fi off, and no account is needed. Docker and GitHub Actions run in the same app, if you ever want them.
            </p>
            <div className="mt-8 flex flex-wrap items-center justify-center gap-3 md:justify-start">
              <DownloadButton />
              <GithubButton />
            </div>
            <Command command="brew install --cask ansumanshah/tap/noodle" className="mx-auto mt-4 w-full max-w-[27rem] md:mx-0" />
            <div className="mt-3 flex flex-wrap items-center justify-center gap-x-4 gap-y-1 text-xs text-muted md:justify-start">
              <span>Apple silicon · macOS 26 or later</span>
              <span aria-hidden="true" className="text-faint max-sm:hidden">/</span>
              <AgentSetupButton compact />
            </div>
          </div>
        </section>
      </div>
      <section className="shell border-t border-line pt-10 pb-8 text-center" aria-label="Noodle screens">
        <Reveal delay={0.04} className="mx-auto max-w-[1040px]">
          <HeroScreens screens={screens} />
        </Reveal>

        <ul aria-label="Works with" className="mx-auto mt-8 flex max-w-3xl flex-wrap items-center justify-center gap-2">
          <li className="mr-1 text-xs text-faint">Works with</li>
          {worksWith.map((w) => (
            <li key={w} className="inline-flex h-chip items-center rounded-panel border border-line bg-raised px-3 font-mono text-[0.78rem] text-muted">
              {w}
            </li>
          ))}
        </ul>
      </section>
    </>
  );
}
