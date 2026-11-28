import Link from 'next/link';
import { ChatDemo } from '@/components/motion/ChatDemo';
import { CiBill } from '@/components/product/CiBill';
import { DownloadButton } from '@/components/site/DownloadButton';
import { Command } from '@/components/ui/Command';
import { Reveal } from '@/components/ui/Reveal';
import { shot } from '@/lib/media';
import { product } from '@/lib/site';
import { ConnectSnippets } from './ConnectSnippets';
import { JobTimeline, WhatRunsWhere } from './Diagrams';
import { GithubButton } from './Hero';
import { Screenshot } from './Media';

const link = 'font-medium text-[var(--accent-ink)] hover:underline';

interface HeadingProps {
  id: string;
  eyebrow: string;
  title: string;
  children?: React.ReactNode;
}

function Heading({ id, eyebrow, title, children }: HeadingProps) {
  return (
    <Reveal className="max-w-2xl">
      <p className="eyebrow">{eyebrow}</p>
      <h2 id={id} className="display mt-3 text-balance text-[clamp(2rem,4.4vw,3rem)]">
        {title}
      </h2>
      {children ? <p className="mt-4 text-muted">{children}</p> : null}
    </Reveal>
  );
}

// ---------------------------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------------------------
export function ModelsSection() {
  return (
    <section id="models" aria-labelledby="models-title" className="shell mt-24 scroll-mt-24 border-t border-line pt-16 md:mt-32 md:pt-20">
      <div className="tone-models grid grid-cols-[minmax(0,1fr)] items-start gap-10 md:grid-cols-[minmax(0,1.08fr)_minmax(0,0.92fr)] md:gap-14">
        <Reveal>
          <p className="eyebrow">Models</p>
          <h2 id="models-title" className="display mt-3 text-balance text-[clamp(2rem,4.4vw,3rem)]">
            Pick a model. Press Run.
          </h2>
          <p className="mt-4 text-muted">
            Weights run on your Mac&apos;s own chip, both GGUF and MLX. Press Control-Option-Space to chat from any app, make images or speech in Create, add Open WebUI, AnythingLLM or n8n from Apps, or point your own tools at <code className="rounded bg-surface px-1.5 py-0.5 font-mono text-[0.86em] text-ink">http://models.noodle.local/v1</code>.
          </p>
          <ConnectSnippets />
          <div className="mt-5 flex flex-wrap items-center gap-x-5 gap-y-2 text-sm">
            <Link href="/models/" className="font-medium text-[var(--p-ink)] hover:underline">
              Explore Models <span aria-hidden="true">→</span>
            </Link>
            <Link href="/docs/models/api/" className="text-muted hover:text-ink hover:underline">
              Local API reference <span aria-hidden="true">→</span>
            </Link>
          </div>
        </Reveal>
        <Reveal delay={0.05} className="grid gap-3">
          <ChatDemo />
          <p className="px-1 text-xs leading-relaxed text-faint">
            312 ms to the first words on Qwen3 0.6B GGUF (M4 Mac mini). Ollama 0.40.16 decodes about 1.3× faster and uses half the memory.{' '}
            <Link href="/docs/benchmarks/#models" className="underline hover:text-ink">
              Models benchmark
            </Link>
          </p>
        </Reveal>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------------------------
// Containers and VMs
// Numbers checked against public/data/fresh-boot-resources.json, engines.json, daemon-footprint.json:
// - "22x": API p50 bridge, Noodle 5.51 ms vs OrbStack 2.2.5 123.83 ms, 2 vCPU / 8 GiB, fresh boots.
// - "3.2x": docker run p50 bridge, Noodle 14.97 ms vs Kiri 0.2.2 48.10 ms, 4 vCPU / 2 GiB.
// - "6.5 MB": daemon physical footprint after full benchmark (6.47 to 6.74 MB), VM asleep.
// - Loss: Kiri 0.2.2 cold pull is 2.8x faster (896.03 ms vs 2539.81 ms).
// ---------------------------------------------------------------------------------------------
const containerFacts = [
  'docker, Compose, Buildx and Kubernetes work as they are.',
  'Each web container gets a name like api.localhost over HTTP or HTTPS, with no sudo and no hosts-file edit.',
  'amd64 images run through Rosetta, and the Linux VM sleeps when idle so the daemon uses 6.5 MB.',
];

const containerProof = [
  { value: '22×', label: 'faster container start than OrbStack', note: 'Docker API p50, bridge, 2 vCPU / 8 GiB, fresh VM boots' },
  { value: '3.2×', label: 'faster docker run than Kiri', note: 'docker run p50, bridge, Kiri 0.2.2, 4 vCPU / 2 GiB' },
  { value: '6.5 MB', label: 'daemon memory while idle', note: 'Physical footprint after the full benchmark, VM asleep' },
];

export function ContainersSection() {
  const c = product('containers');
  return (
    <section id="containers" aria-labelledby="containers-title" className="shell tone-containers mt-24 scroll-mt-24 border-t border-line pt-16 md:mt-32 md:pt-20">
      <Heading id="containers-title" eyebrow="Containers and VMs" title="Containers, when you need them.">
        Models need none of this. When you do need containers, switch one Docker context instead of running a heavier desktop app.
      </Heading>

      <Reveal className="mt-10 grid grid-cols-[minmax(0,1fr)] items-center gap-8 rounded-card border border-line bg-raised p-5 sm:p-8 md:grid-cols-[minmax(0,1.25fr)_minmax(0,1fr)] md:gap-12 md:p-10">
        <Screenshot
          shot={shot('containers')}
          alt="Noodle Containers: a Compose project with every service running and live logs open."
        />
        <div>
          <h3 className="display text-balance text-[clamp(1.6rem,3vw,2.15rem)]">Same docker commands. Lighter engine.</h3>
          <ul className="mt-5 grid gap-2.5 text-[0.95rem] text-muted">
            {containerFacts.map((f) => (
              <li key={f} className="flex gap-2.5">
                <span aria-hidden="true" className="mt-[0.5em] size-2 shrink-0 rounded-full bg-[var(--p)]" />
                {f}
              </li>
            ))}
          </ul>
          <Command command={c.command} className="mt-6" />
          <div className="mt-5 flex flex-wrap items-center gap-x-5 gap-y-2 text-sm">
            <Link href="/containers/" className="font-medium text-[var(--p-ink)] hover:underline">
              Explore Containers <span aria-hidden="true">→</span>
            </Link>
            <Link href="/docs/containers/migrating/" className="text-muted hover:text-ink hover:underline">
              Migrate from Docker Desktop or OrbStack <span aria-hidden="true">→</span>
            </Link>
          </div>
        </div>
      </Reveal>

      <Reveal className="mt-6 grid gap-6">
        <WhatRunsWhere />
        <dl className="grid gap-4 sm:grid-cols-3">
          {containerProof.map((p) => (
            <div key={p.value} className="rounded-card border border-line bg-raised p-5">
              <dt className="text-sm text-muted">{p.label}</dt>
              <dd className="display mt-1 text-[2.4rem] tabular-nums">{p.value}</dd>
              <dd className="mt-1 text-xs text-faint">{p.note}</dd>
            </div>
          ))}
        </dl>
        <p className="text-sm text-muted">
          Cold image pulls are 2.8× faster on Kiri 0.2.2 (896.03 ms vs 2539.81 ms).{' '}
          <Link href="/docs/benchmarks/" className={link}>
            Every number, the losses too, with raw data <span aria-hidden="true">→</span>
          </Link>
        </p>
      </Reveal>
    </section>
  );
}

// ---------------------------------------------------------------------------------------------
// CI Runners
// ---------------------------------------------------------------------------------------------
const workflowDiffs = [
  {
    os: 'Linux jobs (arm64 container)',
    before: 'runs-on: ubuntu-latest',
    after: 'runs-on: [self-hosted, noodle]',
  },
  {
    os: 'macOS jobs (Xcode on your Mac)',
    before: 'runs-on: macos-latest',
    after: 'runs-on: [self-hosted, noodle-macos]',
  },
];

export function RunnersSection() {
  const p = product('runners');
  return (
    <section id="runners" aria-labelledby="runners-title" className="shell tone-runners mt-24 scroll-mt-24 border-t border-line pt-16 md:mt-32 md:pt-20">
      <div className="grid grid-cols-[minmax(0,1fr)] items-start gap-8 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)] md:gap-12">
        <Reveal>
          <p className="eyebrow">GitHub Actions</p>
          <h2 id="runners-title" className="display mt-3 text-balance text-[clamp(2rem,4.4vw,3rem)]">
            Your Mac takes your CI jobs.
          </h2>
          <p className="mt-4 text-muted">
            Change one line in a workflow and its jobs run on your Mac instead of waiting on a hosted queue. Each job gets a fresh runner that is removed when it finishes. Private repos only by default.
          </p>
          <Command command={p.command} className="mt-6 max-w-md" />
          <div className="mt-5 flex flex-wrap items-center gap-x-5 gap-y-2 text-sm">
            <Link href="/runners/" className="font-medium text-[var(--p-ink)] hover:underline">
              Explore Runners <span aria-hidden="true">→</span>
            </Link>
            <Link href="/docs/runners/quickstart/" className="text-muted hover:text-ink hover:underline">
              Runner quickstart <span aria-hidden="true">→</span>
            </Link>
          </div>
        </Reveal>

        <Reveal delay={0.05} className="grid gap-3">
          {workflowDiffs.map((d) => (
            <div key={d.os} className="rounded-card border border-line bg-raised p-4">
              <p className="text-xs font-medium text-muted">{d.os}</p>
              <pre className="mt-2 overflow-x-auto rounded-control bg-surface p-3 font-mono text-[0.82rem] leading-relaxed">
                <code>
                  <span className="block text-[var(--stop)]">- {d.before}</span>
                  <span className="block text-[var(--p-ink)]">+ {d.after}</span>
                </code>
              </pre>
            </div>
          ))}
        </Reveal>
      </div>

      <Reveal className="mt-8 grid gap-6">
        <CiBill />
        <JobTimeline />
      </Reveal>
    </section>
  );
}

// ---------------------------------------------------------------------------------------------
// Before you install: plain limits, architecture and scriptability.
// ---------------------------------------------------------------------------------------------
const disclosures = [
  {
    term: 'Native footprint',
    detail:
      'SwiftUI app, Swift daemon, static Zig guest agent on Apple Virtualization.framework. No Electron or bundled browser. 6.5 MB daemon footprint while the VM sleeps.',
  },
  {
    term: 'Scripts and tools',
    detail:
      'With --json a command prints one JSON document on stdout and everything else on stderr. Exit codes are fixed (0 ok, 1 failed, 2 usage, 3 engine not running), and --yes skips confirmations. Full index at /llms.txt.',
  },
  {
    term: 'Known limits in 26.11.7',
    detail:
      'Targets Apple silicon on macOS 26 or later (built and tested on macOS 27; macOS 26 itself is untested). Privileged container boundaries have not had an outside security review. Cold image pulls trail Kiri 0.2.2, and small GGUF decode trails Ollama.',
  },
  {
    term: 'Licence',
    detail:
      'Noodle is Apache-2.0. The guest Linux kernel configuration and build scripts follow GPL-2.0, with matching sources attached to each release on the licences page.',
  },
];

export function BeforeYouInstall() {
  return (
    <section aria-labelledby="limits-title" className="shell mt-24 border-t border-line pt-16 md:mt-32 md:pt-20">
      <Heading id="limits-title" eyebrow="Before you install" title="What ships today, and what does not." />
      <dl className="mt-10 divide-y divide-[var(--line)] border-y border-line">
        {disclosures.map((row) => (
          <div key={row.term} className="grid gap-2 py-5 md:grid-cols-[220px_1fr] md:gap-8">
            <dt className="text-sm font-semibold text-ink">{row.term}</dt>
            <dd className="text-[0.95rem] leading-relaxed text-muted">{row.detail}</dd>
          </div>
        ))}
      </dl>
    </section>
  );
}

// ---------------------------------------------------------------------------------------------
// Closing CTA
// ---------------------------------------------------------------------------------------------
export function ClosingCta() {
  return (
    <section aria-labelledby="cta-title" className="shell mt-20 text-center md:mt-28">
      <Reveal className="rounded-card border border-line bg-raised px-6 py-14 md:py-20">
        <h2 id="cta-title" className="display mx-auto max-w-[18ch] text-[clamp(2.1rem,5vw,3.4rem)]">
          Pick a model and try it.
        </h2>
        <p className="mx-auto mt-4 max-w-[48ch] text-muted">
          Noodle adds its own Docker context and never touches your existing containers, models or hosts file. Apple silicon, macOS 26 or later.
        </p>
        <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
          <DownloadButton />
          <GithubButton />
        </div>
        <Command command="brew install --cask ansumanshah/tap/noodle" className="mx-auto mt-5 w-full max-w-[27rem]" />
      </Reveal>
    </section>
  );
}
