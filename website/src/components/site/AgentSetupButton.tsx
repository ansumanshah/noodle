'use client';
import { useEffect, useRef, useState } from 'react';
import { siteConfig } from '@/lib/site';

/** The prompt a coding agent (Claude Code, Codex, Cursor) gets to install and set up Noodle on this Mac. */
export const agentSetupPrompt = `Set up Noodle on this Mac for me. Noodle is a free, open-source Mac app that runs local AI models, Docker containers and GitHub Actions runners.

1. Read ${siteConfig.origin}/llms.txt and ${siteConfig.origin}/llms.mdx/docs/install.md first.
2. Check this is an Apple silicon Mac on macOS 26 or later. If not, stop and tell me.
3. Download ${siteConfig.release.url}, open the disk image, copy Noodle.app to /Applications and open it once.
4. Ask me which parts I want: Models (local AI chat and an OpenAI-style API), Containers (Docker) or Runners (GitHub Actions jobs on this Mac).
5. For Containers, run: /Applications/Noodle.app/Contents/Helpers/noodle setup --no-use. Setup links noodle (and docker, when none is installed) into ~/.local/bin, which this shell may not have on PATH yet, so run ~/.local/bin/noodle start, then ~/.local/bin/noodle status --startup, then docker --context noodle run --rm alpine:3.22 echo hello (use ~/.local/bin/docker if docker is not found).
6. For Models and Runners, follow the quickstart pages listed in llms.txt.

Do not switch my Docker context, change other engines or delete anything without asking me first. When you finish, tell me what you installed and what to try next.`;

export function AgentSetupButton({ compact = false }: { compact?: boolean }) {
  const [done, setDone] = useState(false);
  const timer = useRef<number | undefined>(undefined);
  useEffect(() => () => window.clearTimeout(timer.current), []);

  async function copy() {
    try {
      await navigator.clipboard.writeText(agentSetupPrompt);
      setDone(true);
      window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => setDone(false), 1800);
    } catch (e: unknown) {
      if (!(e instanceof Error)) throw e;
    }
  }

  return (
    <button
      type="button"
      onClick={copy}
      title="Copies a setup prompt for Claude Code, Codex or Cursor"
      className={
        compact
          ? 'spring press inline-flex items-center gap-1.5 text-xs text-muted hover:text-ink underline-offset-4 hover:underline'
          : 'spring press hover-lift inline-flex items-center gap-2 h-control rounded-panel px-4 text-sm font-medium text-muted hover:text-ink'
      }
    >
      <svg width={compact ? 13 : 16} height={compact ? 13 : 16} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        {done ? <path d="M5 12.5l4.5 4.5L19 7.5" /> : <><rect x="9" y="9" width="11" height="11" rx="2" /><path d="M5 15V6a2 2 0 0 1 2-2h9" /></>}
      </svg>
      {done ? 'Prompt copied' : compact ? 'Copy setup prompt' : 'Set up with Claude Code or Cursor'}
      <span className="sr-only" aria-live="polite">{done ? 'Setup prompt copied to the clipboard' : ''}</span>
    </button>
  );
}
