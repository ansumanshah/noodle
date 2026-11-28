import { Fragment } from 'react';
import { CopyButton } from './CopyButton';

// One copyable shell line on a terminal surface. Server component; only the button is client code.
export function Command({ command, className = '' }: { command: string; className?: string }) {
  return (
    <div className={`term flex items-center gap-2 rounded-panel py-1 pr-1.5 pl-3.5 text-[0.8rem] sm:text-[0.86rem] ${className}`}>
      <code className="min-w-0 flex-1 overflow-x-auto whitespace-nowrap py-1.5 text-left max-sm:whitespace-normal">
        <span className="dim select-none">$ </span>
        {/* On a phone the line wraps at spaces only, never inside a name like qwen3.5-4b. */}
        {command.split(' ').map((word, i) => (
          <Fragment key={i}><span className="whitespace-nowrap">{word}</span>{' '}</Fragment>
        ))}
      </code>
      <CopyButton text={command} />
    </div>
  );
}
