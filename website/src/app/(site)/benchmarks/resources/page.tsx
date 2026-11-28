import Link from 'next/link';
import type { Metadata } from 'next';
import { Bars } from '@/components/ui/Bars';
import fresh from '../../../../../public/data/fresh-boot-resources.json';
import matrix from '../../../../../public/data/resources-10-matrix.json';
import startup from '../../../../../public/data/orbstack-startup.json';
import run from '../../../../../public/data/engines.json';

export const metadata: Metadata = {
  title: 'Container benchmarks',
  description: 'Same-Mac measurements of container startup, host CPU and physical memory against OrbStack, Kiri and others.',
  alternates: { canonical: '/benchmarks/resources/' },
};

const freshEngines = new Set(['noodle', 'orbstack']);
const engines = [
  { engine: 'noodle', name: 'Noodle' },
  { engine: 'orbstack', name: 'OrbStack' },
  { engine: 'colima', name: 'Colima' },
  { engine: 'docker-desktop', name: 'Docker Desktop' },
  { engine: 'podman', name: 'Podman' },
];
const startupMetrics = [
  { id: 'cli.run', label: 'Docker CLI' },
  { id: 'api.lifecycle.bridge', label: 'Bridge API' },
  { id: 'api.lifecycle.none', label: 'No-network API' },
] as const;

// Not in the data file: the run records the engine's Docker API version, not the app version.
const kiriVersion = '0.2.2';
const kiriTimes = [
  { id: 'cli.run', label: 'docker run, bridge' },
  { id: 'cli.run.none', label: 'docker run --network none' },
  { id: 'api.lifecycle.bridge', label: 'API lifecycle, bridge' },
  { id: 'api.lifecycle.none', label: 'API lifecycle, no network' },
  { id: 'cli.exec', label: 'docker exec' },
  { id: 'cli.pull.cold', label: 'Cold pull, network' },
] as const;
const kiriStates = [
  { id: 'vm-up-empty', label: 'VM up, no containers' },
  { id: '20-containers', label: '20 containers running' },
  { id: 'after-idle-wait', label: 'After the idle wait' },
] as const;

const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];

export default function ResourceBenchmarks() {
  if ([...fresh.rows, ...fresh.passes].some(({ engine }) => !freshEngines.has(engine))) {
    throw new Error('Unexpected engine in public fresh-boot samples');
  }
  const older = engines.map(({ engine, name }) => {
    const passes = matrix.results.filter((p) => p.engine === engine);
    if (passes.length !== matrix.passesPerEngine) throw new Error(`Incomplete benchmark: ${engine}`);
    return { engine, name, cpu: median(passes.map((p) => p.cpuPercent)), memory: median(passes.map((p) => p.memoryMB)) };
  });
  const timed = fresh.method.freshBootsPerEngine * fresh.method.startupSamplesPerBoot;
  const hl = (engine: string) => engine === 'noodle';
  const { noodle, kiri } = run.engines;

  return (
    <div className="shell py-14 md:py-20">
      <header className="max-w-2xl">
        <p className="eyebrow">Performance</p>
        <h1 className="display mt-4 text-[clamp(2.2rem,5vw,3.4rem)]">Container benchmarks</h1>
        <p className="mt-4 text-muted">
          Noodle against OrbStack and Kiri on one Mac: how much they use with ten containers running, and how long a warm start takes. M4 Mac mini, {fresh.method.vCPUs} vCPUs and {fresh.method.vmMemoryMiB / 1024} GiB per VM, image <code>{fresh.method.image}</code>.
        </p>
        <nav aria-label="On this page" className="mt-5 flex gap-5 text-sm font-medium text-[var(--accent-ink)]">
          <a href="#resources" className="hover:underline">CPU and memory</a>
          <a href="#startup" className="hover:underline">Startup</a>
          <a href="#kiri" className="hover:underline">Kiri</a>
          <a href="#earlier" className="hover:underline">Earlier runs</a>
        </nav>
      </header>

      <section id="resources" className="mt-14 scroll-mt-24">
        <h2 className="text-2xl font-semibold tracking-tight">Ten containers running</h2>
        <p className="mt-2 max-w-2xl text-sm text-muted">Median across {fresh.method.freshBootsPerEngine} fresh VM boots. CPU is a percentage of one host core. Physical memory includes the engine and its VM helper. The Mac was busy with other work during these boots (load average 7.5 to 14.6).</p>
        <div className="mt-5 grid gap-4 md:grid-cols-2">
          <Bars label="Host CPU" unit="%" decimals={2} rows={fresh.rows.map((r) => ({ name: r.name, value: r.hostCPUPercent, highlight: hl(r.engine) }))} />
          <Bars label="Host physical memory" unit="MB" decimals={0} rows={fresh.rows.map((r) => ({ name: r.name, value: r.hostMemoryMB, highlight: hl(r.engine) }))} />
        </div>
      </section>

      <section id="startup" className="mt-14 scroll-mt-24">
        <h2 className="text-2xl font-semibold tracking-tight">Warm container startup</h2>
        <p className="mt-2 max-w-2xl text-sm text-muted">Bars show p50, with p95 beside each value. The CLI runs <code>docker run --rm alpine:3.20 true</code>. The API times create, start, wait and remove.</p>
        <div className="mt-5 grid gap-4 md:grid-cols-3">
          {startupMetrics.map(({ id, label }) => (
            <Bars
              key={id}
              label={label}
              unit="ms"
              decimals={2}
              rows={fresh.rows.map((r) => ({ name: r.name, value: r.startup[id].p50Ms, note: `p95 ${r.startup[id].p95Ms.toFixed(1)}`, highlight: hl(r.engine) }))}
            />
          ))}
        </div>
        <p className="mt-4 text-sm text-muted">
          Each boot used {fresh.method.startupWarmups} warmups and {fresh.method.startupSamplesPerBoot} timed runs. p50 is the median of the boot medians. p95 pools all {timed} timings.{' '}
          <a href="/data/fresh-boot-resources.json" className="font-medium text-[var(--accent-ink)] hover:underline">Raw fresh-boot samples</a>{' · '}
          <Link href="/docs/benchmarks/" className="font-medium text-[var(--accent-ink)] hover:underline">Methodology</Link>
        </p>
      </section>

      <section id="kiri" className="mt-14 scroll-mt-24">
        <h2 className="text-2xl font-semibold tracking-tight">Noodle and Kiri</h2>
        <p className="mt-2 max-w-2xl text-sm text-muted">
          Kiri {kiriVersion} on the same Mac, {run.settings.cpus} vCPUs and {run.settings.memory_mib} MiB per VM. {run.passes} alternating passes, one engine up at a time. Each bar is the median of the per-pass p50s. Memory is the daemon plus its VM helper.
        </p>
        <div className="mt-5 grid gap-4 md:grid-cols-3">
          {kiriStates.map(({ id, label }) => (
            <Bars
              key={id}
              label={label}
              unit="MB"
              decimals={1}
              rows={[
                { name: 'Noodle', value: noodle.footprint_median[id].daemon_mb + noodle.footprint_median[id].vm_helper_mb, highlight: true },
                { name: 'Kiri', value: kiri.footprint_median[id].daemon_mb + kiri.footprint_median[id].vm_helper_mb },
              ]}
            />
          ))}
          {kiriTimes.map(({ id, label }) => (
            <Bars
              key={id}
              label={label}
              unit="ms"
              decimals={2}
              rows={[
                { name: 'Noodle', value: noodle.p50_median_of_passes[id].value, highlight: true },
                { name: 'Kiri', value: kiri.p50_median_of_passes[id].value },
              ]}
            />
          ))}
        </div>
        <p className="mt-4 max-w-2xl text-sm text-muted">
          Where Kiri is ahead: a cold pull finishes {(noodle.p50_median_of_passes['cli.pull.cold'].value / kiri.p50_median_of_passes['cli.pull.cold'].value).toFixed(1)}× sooner, and stdout moves {kiri.p50_median_of_passes['cli.stdout'].value.toFixed(0)} MB/s against {noodle.p50_median_of_passes['cli.stdout'].value.toFixed(0)}. The two no-network rows and <code>docker exec</code> are ties. Noodle&apos;s build test failed in this run and Kiri&apos;s passed. After the idle wait Noodle&apos;s VM had slept and Kiri&apos;s stayed up, which is the whole gap in that chart.{' '}
          <a href="/data/engines.json" className="font-medium text-[var(--accent-ink)] hover:underline">Raw passes</a>{' · '}
          <Link href="/docs/benchmarks/#engines" className="font-medium text-[var(--accent-ink)] hover:underline">All four engines</Link>
        </p>
      </section>

      <details id="earlier" className="mt-14 scroll-mt-24 rounded-card border border-line bg-surface">
        <summary className="cursor-pointer p-5 font-semibold">
          Earlier runs <span className="ml-2 text-sm font-normal text-muted">Five-engine footprint and earlier startup timings</span>
        </summary>
        <div className="grid gap-5 p-5 pt-0">
          <p className="text-sm text-muted">Medians of three matched passes. CPU is the share of one host core over {matrix.cpuWindowSeconds} seconds. OrbStack&apos;s measurements came from one VM session. Docker Desktop&apos;s first pass followed onboarding.</p>
          <div className="grid gap-4 md:grid-cols-2">
            <Bars label="Host CPU" unit="%" decimals={2} rows={older.map((r) => ({ name: r.name, value: r.cpu, highlight: hl(r.engine) }))} />
            <Bars label="Host physical memory" unit="MB" decimals={0} rows={older.map((r) => ({ name: r.name, value: r.memory, highlight: hl(r.engine) }))} />
          </div>
          <div className="grid gap-4 md:grid-cols-3">
            {startupMetrics.map(({ id, label }) => (
              <Bars
                key={id}
                label={`${label}, earlier run`}
                unit="ms"
                decimals={2}
                rows={engines.flatMap(({ engine, name }) => {
                  const s = startup.results.find((row) => row.engine === engine && row.metric === id);
                  return s ? [{ name, value: s.p50Ms, note: `p95 ${s.p95Ms.toFixed(1)}`, highlight: hl(engine) }] : [];
                })}
              />
            ))}
          </div>
          <p className="text-sm">
            <a href="/data/resources-10-matrix.json" className="font-medium text-[var(--accent-ink)] hover:underline">Raw footprint passes</a>{' · '}
            <a href="/data/orbstack-startup.json" className="font-medium text-[var(--accent-ink)] hover:underline">Raw startup samples</a>
          </p>
        </div>
      </details>
    </div>
  );
}
