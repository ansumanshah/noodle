// One place for facts the pages share. Change here, not in components.

export interface Product {
  id: 'containers' | 'models' | 'runners';
  name: string;
  tagline: string;
  href: string;
  command: string;
  links: { label: string; href: string }[];
}

export const siteConfig = {
  name: 'Noodle',
  origin: process.env.NEXT_PUBLIC_SITE_URL ?? 'https://getnoodle.dev',
  author: 'Ansuman Shah',
  /** GitHub "owner/repo". */
  repo: 'ansumanshah/noodle',
  /** The current release. The DMG is attached to the GitHub release of the same tag. */
  release: {
    version: '26.11.7',
    /** Feed metadata only (releases.xml); never rendered. */
    date: '2026-11-25',
    url: 'https://github.com/ansumanshah/noodle/releases/download/v26.11.7/Noodle-26.11.7.dmg',
    notes: 'https://github.com/ansumanshah/noodle/releases/tag/v26.11.7',
  },
};

export const products: Product[] = [
  {
    id: 'models',
    name: 'Noodle Models',
    tagline: 'Chat with AI that runs on your Mac, and plug it into your tools.',
    href: '/docs/models/',
    command: 'noodle model run qwen3.5-4b',
    links: [
      { label: 'Quickstart', href: '/docs/models/quickstart/' },
      { label: 'Catalog and import', href: '/docs/models/catalog/' },
      { label: 'Local API', href: '/docs/models/api/' },
    ],
  },
  {
    id: 'containers',
    name: 'Noodle Containers',
    tagline: 'Your Docker and Compose commands, on a lighter engine.',
    href: '/docs/containers/',
    command: 'docker run --rm alpine echo hello',
    links: [
      { label: 'Quickstart', href: '/docs/containers/quickstart/' },
      { label: 'Containers and Compose', href: '/docs/containers/' },
      { label: 'Images and builds', href: '/docs/containers/images/' },
    ],
  },
  {
    id: 'runners',
    name: 'Noodle Runners',
    tagline: 'GitHub Actions jobs on your own Mac, Linux and macOS. A fresh runner per job.',
    href: '/docs/runners/',
    command: 'noodle runners add owner/repo',
    links: [
      { label: 'Quickstart', href: '/docs/runners/quickstart/' },
      { label: 'Labels', href: '/docs/runners/labels/' },
      { label: 'macOS jobs', href: '/docs/runners/macos/' },
    ],
  },
];

export const product = (id: Product['id']) => products.find((p) => p.id === id)!;

export const commonPaths = [
  { label: 'Get Noodle on your Mac', href: '/docs/install/' },
  { label: 'Run your first container', href: '/docs/containers/quickstart/' },
  { label: 'Chat with a model on your Mac', href: '/docs/models/quickstart/' },
  { label: 'Run GitHub Actions jobs on your Mac', href: '/docs/runners/quickstart/' },
  { label: 'Move over from Docker Desktop or OrbStack', href: '/docs/containers/migrating/' },
  { label: 'Let your AI tools use Noodle', href: '/docs/agents/' },
  { label: 'Something is not working', href: '/docs/troubleshooting/' },
  { label: 'Every command, in one list', href: '/docs/cli/' },
];
