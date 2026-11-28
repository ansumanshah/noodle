'use client';
import { useRef, useState, type KeyboardEvent } from 'react';
import { CopyButton } from '@/components/ui/CopyButton';

interface Snippet {
  id: string;
  label: string;
  code: string;
}

const snippets: Snippet[] = [
  {
    id: 'claude',
    label: 'Claude Code',
    code: `export ANTHROPIC_BASE_URL=http://models.noodle.local
export ANTHROPIC_AUTH_TOKEN="$(noodle model key)"
export ANTHROPIC_MODEL=qwen3.5-4b
claude`,
  },
  {
    id: 'openai',
    label: 'OpenAI / Codex',
    code: `export OPENAI_BASE_URL=http://models.noodle.local/v1
export OPENAI_API_KEY="$(noodle model key)"`,
  },
  {
    id: 'curl',
    label: 'curl',
    code: `curl http://models.noodle.local/v1/chat/completions \\
  -H "Authorization: Bearer $(noodle model key)" \\
  -H 'Content-Type: application/json' \\
  -d '{"model":"qwen3.5-4b","messages":[{"role":"user","content":"Hello"}]}'`,
  },
  {
    id: 'images',
    label: 'Images',
    code: `curl http://models.noodle.local/v1/images/generations \\
  -H "Authorization: Bearer $(noodle model key)" \\
  -H 'Content-Type: application/json' \\
  -d '{"model":"flux2-klein-4b","prompt":"A paper boat on a pond"}'`,
  },
];

// Connects local tools to Noodle Models. Uses ARIA tablist + roving tabIndex without aria-controls.
export function ConnectSnippets() {
  const [active, setActive] = useState(0);
  const tabRefs = useRef<(HTMLButtonElement | null)[]>([]);

  const selectTab = (index: number) => {
    setActive(index);
    tabRefs.current[index]?.focus();
  };

  const onKeyDown = (e: KeyboardEvent<HTMLButtonElement>, i: number) => {
    let next = -1;
    if (e.key === 'ArrowRight') next = (i + 1) % snippets.length;
    else if (e.key === 'ArrowLeft') next = (i - 1 + snippets.length) % snippets.length;
    else if (e.key === 'Home') next = 0;
    else if (e.key === 'End') next = snippets.length - 1;
    if (next < 0) return;
    e.preventDefault();
    selectTab(next);
  };

  const current = snippets[active];

  return (
    <div className="tone-models mt-6 overflow-hidden rounded-card border border-[#25222b] bg-[var(--term-bg)] text-[var(--term-text)]">
      <div className="flex items-center justify-between gap-2 border-b border-[#25222b] px-2 pt-1.5">
        <div role="tablist" aria-label="Local API clients" className="tab-strip flex flex-nowrap items-center gap-1 overflow-x-auto pb-1">
          {snippets.map((s, i) => {
            const on = i === active;
            return (
              <button
                key={s.id}
                ref={(el) => {
                  tabRefs.current[i] = el;
                }}
                type="button"
                role="tab"
                id={`api-tab-${s.id}`}
                aria-selected={on}
                tabIndex={on ? 0 : -1}
                onClick={() => setActive(i)}
                onKeyDown={(e) => onKeyDown(e, i)}
                className={`tab-btn spring h-chip shrink-0 rounded-control px-1.5 text-xs font-medium sm:px-2.5 ${
                  on ? 'text-white' : 'text-[var(--term-dim)] hover:text-white'
                }`}
              >
                {s.label}
              </button>
            );
          })}
        </div>
        <CopyButton text={current.code} label={`Copy ${current.label} example`} />
      </div>
      {snippets.map((s, i) => {
        const on = i === active;
        return (
          <div
            key={s.id}
            role="tabpanel"
            aria-labelledby={`api-tab-${s.id}`}
            hidden={!on}
            className={on ? 'tab-panel-in' : undefined}
          >
            <pre className="term overflow-x-auto border-0 p-4 font-mono text-[0.79rem] leading-relaxed">
              <code>{s.code}</code>
            </pre>
          </div>
        );
      })}
    </div>
  );
}
