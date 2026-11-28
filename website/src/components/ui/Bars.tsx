export interface BarRow {
  name: string;
  value: number;
  highlight?: boolean;
  note?: string;
}

interface BarsProps {
  label: string;
  unit: string;
  rows: BarRow[];
  decimals?: number;
}

// Horizontal bars drawn with scaleX, so the chart is server-rendered and never reflows.
export function Bars({ label, unit, rows, decimals = 1 }: BarsProps) {
  const max = Math.max(...rows.map((r) => r.value));
  return (
    <figure className="rounded-card border border-line bg-raised p-5">
      <figcaption className="flex items-baseline justify-between">
        <span className="text-sm font-semibold">{label}</span>
        <span className="text-xs text-faint">{unit}, lower is better</span>
      </figcaption>
      <dl className="mt-4 grid gap-3">
        {rows.map((r) => (
          <div key={r.name}>
            <div className="flex items-baseline justify-between text-sm">
              <dt className={r.highlight ? 'font-semibold' : 'text-muted'}>{r.name}</dt>
              <dd className="font-mono text-[0.82rem]">
                {r.value.toFixed(decimals)} <span className="text-faint">{unit}</span>
                {r.note ? <span className="ml-2 text-faint">{r.note}</span> : null}
              </dd>
            </div>
            <div className="mt-1.5 h-2 overflow-hidden rounded-full bg-surface">
              <div
                className="h-full origin-left rounded-full"
                style={{ transform: `scaleX(${max > 0 ? r.value / max : 0})`, background: r.highlight ? 'var(--accent)' : 'var(--faint)' }}
              />
            </div>
          </div>
        ))}
      </dl>
    </figure>
  );
}
