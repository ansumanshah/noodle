import { InView } from '@/components/motion/InView';

// Inline SVG diagrams drawn from theme tokens, so they follow light and dark. Moving dashes stop under Reduce Motion.

export function WhatRunsWhere() {
  return (
    <InView className="rounded-card border border-line bg-raised p-4 sm:p-6">
      <svg viewBox="0 0 760 170" className="h-auto w-full" role="img" aria-labelledby="wrw-title">
        <title id="wrw-title">The docker CLI talks to Noodle on your Mac, which runs every container in one small Linux VM.</title>
        <g fontFamily="var(--font-sans)">
          <rect x="10" y="50" width="180" height="70" rx="14" fill="var(--surface)" stroke="var(--line)" />
          <text x="100" y="82" textAnchor="middle" fontSize="15" fontWeight="600" fill="var(--ink)">docker CLI</text>
          <text x="100" y="102" textAnchor="middle" fontSize="12" fill="var(--muted)">your terminal, unchanged</text>
          <rect x="290" y="50" width="180" height="70" rx="14" fill="var(--containers-soft)" />
          <text x="380" y="82" textAnchor="middle" fontSize="15" fontWeight="700" fill="var(--containers-ink)">Noodle</text>
          <text x="380" y="102" textAnchor="middle" fontSize="12" fill="var(--containers-ink)">6.5 MB while idle</text>
          <rect x="570" y="30" width="180" height="110" rx="14" fill="var(--surface)" stroke="var(--containers)" strokeDasharray="5 5" />
          <text x="660" y="58" textAnchor="middle" fontSize="15" fontWeight="600" fill="var(--ink)">One Linux VM</text>
          {[0, 1, 2].map((i) => (
            <rect key={i} className="crate" style={{ transitionDelay: `${i * 120}ms` }} x={598 + i * 44} y="76" width="36" height="36" rx="7" fill="var(--containers)" opacity={0.55 + i * 0.2} />
          ))}
          <text x="660" y="130" textAnchor="middle" fontSize="12" fill="var(--muted)">sleeps when nothing runs</text>
          <line x1="190" y1="85" x2="290" y2="85" stroke="var(--containers)" strokeWidth="2.5" strokeDasharray="6 8" />
          <line x1="470" y1="85" x2="570" y2="85" stroke="var(--containers)" strokeWidth="2.5" strokeDasharray="6 8" />
          <circle cx="196" cy="85" r="5" fill="var(--containers)" className="flow-dot" />
          <circle cx="476" cy="85" r="5" fill="var(--containers)" className="flow-dot" style={{ animationDelay: '0.7s' }} />
        </g>
      </svg>
    </InView>
  );
}

const jobSteps = ['git push', 'GitHub queues the job', 'A fresh runner starts', 'The job runs on your Mac', 'The runner is removed'];

export function JobTimeline() {
  return (
    <InView progress className="job-timeline rounded-card border border-line bg-raised p-4 sm:p-6">
      <ol className="relative grid gap-4 sm:grid-cols-5 sm:gap-2" aria-label="The life of one job">
        <span aria-hidden="true" className="absolute top-[11px] right-[10%] left-[10%] hidden h-[3px] overflow-hidden sm:block">
          <span className="flow-track block h-full w-[calc(100%+14px)]" />
        </span>
        {jobSteps.map((s, i) => (
          <li key={s} className="relative flex items-center gap-3 sm:flex-col sm:text-center">
            <span aria-hidden="true" className="relative z-[1] size-6 shrink-0 rounded-full border-[3px] border-[var(--runners)] bg-raised">
              <span className="job-dot absolute inset-[3px] rounded-full bg-[var(--runners)]" style={{ ['--t' as string]: (i / (jobSteps.length - 1)) * 0.9 }} />
            </span>
            <span className="text-sm text-ink">{s}</span>
          </li>
        ))}
        <li aria-hidden="true" className="pointer-events-none absolute top-[-30px] right-[10%] left-[10%] hidden sm:block">
          <span className="job-mover block">
            <span className="job-card inline-block -translate-x-1/2 rounded-full bg-[var(--runners)] px-2.5 py-0.5 font-mono text-[0.72rem] text-[var(--paper)] shadow-[var(--shadow)]">
              test #42
            </span>
          </span>
        </li>
      </ol>
    </InView>
  );
}
