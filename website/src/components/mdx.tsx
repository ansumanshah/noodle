import defaultMdxComponents from 'fumadocs-ui/mdx';
import type { MDXComponents } from 'mdx/types';

// Fumadocs' default pre renders a code block with a copy button, so every fenced command is copyable.
export function getMDXComponents(components?: MDXComponents) {
  return { ...defaultMdxComponents, ...components } satisfies MDXComponents;
}

export const useMDXComponents = getMDXComponents;

declare global {
  type MDXProvidedComponents = ReturnType<typeof getMDXComponents>;
}
