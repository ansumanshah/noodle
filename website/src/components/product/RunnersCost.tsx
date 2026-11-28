import { Reveal } from '@/components/ui/Reveal';
import { CiBill } from '@/components/product/CiBill';

interface Swap {
  os: string;
  before: string;
  after: string;
  note: string;
}

const swaps: Swap[] = [
  { os: 'Linux', before: 'runs-on: ubuntu-latest', after: 'runs-on: [self-hosted, noodle]', note: 'A container on Noodle’s engine, arm64.' },
  { os: 'macOS', before: 'runs-on: macos-latest', after: 'runs-on: [self-hosted, noodle-macos]', note: 'Add xcode-26 to the list to pin an Xcode. Turn macOS on per repo with noodle runners add --macos.' },
];

// Cost, the one-line switch and the data path, for /runners/ only. The calculator is the one client component.
export function RunnersCost() {
  return (
    <section aria-labelledby="cost-title" className="shell mt-20 md:mt-28">
      <Reveal className="max-w-3xl">
        <p className="eyebrow">What hosted CI costs</p>
        <h2 id="cost-title" className="display mt-4 text-balance text-[clamp(2rem,4.4vw,3rem)]">GitHub bills by the minute. Your Mac doesn’t.</h2>
      </Reveal>
      <Reveal className="mt-8">
        <CiBill />
      </Reveal>

      <Reveal className="mt-14 max-w-3xl">
        <h3 className="display text-[clamp(1.5rem,3vw,2rem)]">The switch is one line.</h3>
      </Reveal>
      <div className="mt-6 grid grid-cols-[minmax(0,1fr)] gap-4 md:grid-cols-2">
        {swaps.map((s, i) => (
          <Reveal key={s.os} delay={i * 0.05}>
            <div className="h-full min-w-0 rounded-card border border-line bg-raised p-6">
              <h4 className="text-lg font-semibold">{s.os}</h4>
              <pre className="mt-4 overflow-x-auto rounded-control bg-surface p-3 text-[0.85rem] leading-relaxed"><code><span className="text-[var(--stop)]">- {s.before}</span>{'\n'}<span className="text-[var(--p-ink)]">+ {s.after}</span></code></pre>
              <p className="mt-3 text-[0.95rem] text-muted">{s.note}</p>
            </div>
          </Reveal>
        ))}
      </div>

      <Reveal className="mt-10 max-w-3xl">
        <h3 className="display text-[clamp(1.5rem,3vw,2rem)]">Where your code goes.</h3>
        <p className="mt-3 text-muted">
          GitHub’s own runner talks only to GitHub, with no Noodle server sitting in between. Two limits stay: private repos only by default, and macOS jobs run as your user, unsandboxed.
        </p>
      </Reveal>
    </section>
  );
}
