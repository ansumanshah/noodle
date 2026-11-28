import type { Product } from './site';

// Copy and numbers for the three product pages and the hero. Every stat names its source;
// every use case is something the docs or tests show working today.

export interface Stat {
  value: string;
  label: string;
  /** Where the number comes from, shown in small type. */
  source: string;
  /** Optional same-Mac comparison drawn as two bars, lower is better. */
  bar?: { us: number; them: number; name: string };
  /** Other measured comparisons, stepped together with the paired stat. */
  alts?: Stat[];
}

export interface UseCase {
  title: string;
  text: string;
  code?: string;
}

export interface ProductPage {
  id: Product['id'];
  eyebrow: string;
  title: string;
  lede: string;
  caption: string;
  alt: string;
  stats: [Stat, Stat];
  best: string;
  bestText: string;
  cases: UseCase[];
  faq: { q: string; a: string }[];
}

export const pages: Record<Product['id'], ProductPage> = {
  models: {
    id: 'models',
    eyebrow: 'Noodle Models',
    title: 'AI that runs on your Mac.',
    lede: 'Pick a model, press Run. Works offline after the download.',
    caption: 'Chat with a model on your Mac. Nothing leaves it.',
    alt: 'Noodle Models: a chat with a local model answering on this Mac.',
    stats: [
      { value: '312 ms', label: 'to the first words of a reply', source: 'Long prompt, Qwen3 0.6B GGUF, M4 Mac mini. Ollama decodes 1.3× faster' },
      { value: '0 bytes', label: 'of your chats sent anywhere', source: 'Models run on this Mac' },
    ],
    best: 'Work you cannot send to a cloud tool.',
    bestText: 'Contracts, customer data, unreleased code.',
    cases: [
      { title: 'OpenAI and Anthropic compatible endpoint', text: 'Chat Completions, Responses, Anthropic Messages, embeddings and speech on a local URL with a key.', code: 'noodle model serve qwen3.5-4b' },
      { title: 'Bring any GGUF or MLX model', text: 'From the catalog, or straight from Hugging Face.', code: 'noodle model pull hf.co/<org>/<repo>' },
      { title: 'Chat with pictures, video and audio', text: 'Drop an image, video or audio clip into the message box, if the model supports it.' },
      { title: 'Ask from anywhere', text: 'Control-Option-Space opens chat from any app. Shortcuts and Spotlight work too.' },
      { title: 'Create images, speech and clips', text: 'Images, speech and short videos, generated on this Mac.' },
      { title: 'One-click AI apps', text: 'Open WebUI, AnythingLLM or n8n, wired to your local model.' },
      { title: 'Control memory and disk location', text: 'Unload after 30 seconds, 5 minutes or 1 hour. Keep downloads on an external drive.', code: 'noodle model location /Volumes/Fast/models' },
      { title: 'Share on your local network', text: 'Off by default. Devices on your network need your API key.', code: 'noodle model network on' },
    ],
    faq: [
      { q: 'Does it need the internet?', a: 'Only to download a model. After that, chats run with Wi-Fi off.' },
      { q: 'How do my own apps use it?', a: 'noodle model endpoint prints a URL, a model ID and a key. Any OpenAI or Anthropic client works.' },
      { q: 'Can other devices use my models?', a: 'Only if you turn it on. Every request needs your key, and the connection is plain HTTP, so use a network you trust.' },
    ],
  },
  containers: {
    id: 'containers',
    eyebrow: 'Noodle Containers',
    title: 'Same docker commands. Lighter engine.',
    lede: 'docker, Compose, Buildx and Kubernetes work as they are, in one small Linux VM that sleeps when idle.',
    caption: 'A Compose project running, with live logs beside it.',
    alt: 'Noodle Containers: a Compose project with every service running and the API logs open.',
    // One pair per engine, both columns against the same engine, all measured on this M4 Mac. Medians.
    // Kiri rows from the same-Mac engines run (Kiri 0.2.2); the rest from ten containers running (fresh boots for OrbStack, three passes otherwise).
    stats: [
      {
        value: '22×', label: 'faster container start than OrbStack', source: 'Docker API p50, 2 vCPU / 8 GiB, fresh boots', bar: { us: 5.51, them: 123.83, name: 'OrbStack' },
        alts: [
          { value: '3.2×', label: 'faster docker run than Kiri', source: 'docker run p50, bridge, Kiri 0.2.2, 4 vCPU / 2 GiB', bar: { us: 14.97, them: 48.1, name: 'Kiri' } },
          { value: '6.3×', label: 'less memory than Docker Desktop', source: 'Ten containers, 2 vCPU / 8 GiB, three passes', bar: { us: 232, them: 1472.7, name: 'Docker Desktop' } },
          { value: '5.3×', label: 'less memory than Podman', source: 'Ten containers, 2 vCPU / 8 GiB, three passes', bar: { us: 232, them: 1223, name: 'Podman' } },
          { value: '5×', label: 'less memory than Colima', source: 'Ten containers, 2 vCPU / 8 GiB, three passes', bar: { us: 232, them: 1167, name: 'Colima' } },
        ],
      },
      {
        value: '3.4×', label: 'less CPU than OrbStack', source: 'Ten containers, 2 vCPU / 8 GiB, fresh boots', bar: { us: 0.25, them: 0.85, name: 'OrbStack' },
        alts: [
          { value: '1.7×', label: 'less memory than Kiri while idle', source: 'Daemons only, Noodle’s VM asleep; Kiri 0.2.2 kept a 263 MB VM helper up; 4 vCPU / 2 GiB', bar: { us: 8.6, them: 15, name: 'Kiri' } },
          { value: '8.8×', label: 'less CPU than Docker Desktop', source: 'Ten containers, 2 vCPU / 8 GiB, three passes', bar: { us: 0.2, them: 1.75, name: 'Docker Desktop' } },
          { value: '6.8×', label: 'less CPU than Podman', source: 'Ten containers, 2 vCPU / 8 GiB, three passes', bar: { us: 0.2, them: 1.35, name: 'Podman' } },
          { value: '2.8×', label: 'less CPU than Colima', source: 'Ten containers, 2 vCPU / 8 GiB, three passes', bar: { us: 0.2, them: 0.55, name: 'Colima' } },
        ],
      },
    ],
    best: 'Your team’s Compose stack, as is.',
    bestText: 'Web, API, Postgres and Redis from the docker compose up you already run.',
    cases: [
      { title: 'Switch from Docker Desktop or OrbStack', text: 'A Docker context beside your current engine. Import images and volumes when ready.', code: 'docker context use noodle' },
      { title: 'Builds and multi-arch images', text: 'docker build and Buildx work. amd64 images run through Rosetta.', code: 'docker buildx build --platform linux/amd64 .' },
      { title: 'Single-node Kubernetes', text: 'A local k3s cluster on the same engine.', code: 'noodle kubernetes start' },
      { title: 'Full Linux machines', text: 'Ubuntu or Alpine VMs with shared folders and a shell.', code: 'noodle machine create dev --distro ubuntu' },
      { title: 'Names, not ports', text: 'Web containers answer at name.localhost. WebSockets and hot reload work.', code: 'noodle names add api.myapp 3000' },
      { title: 'See inside every container', text: 'Logs, live CPU and memory, files and a terminal per container. Image scans and SBOMs.' },
    ],
    faq: [
      { q: 'Do my docker commands change?', a: 'No. Noodle speaks the Docker Engine API, so the docker CLI, Compose and Buildx work as they are.' },
      { q: 'Can I keep Docker Desktop or OrbStack?', a: 'Yes. Switch per command with --context.' },
      { q: 'Do I need sudo for .localhost names?', a: 'No. Noodle listens on 80 and 443 without root and edits no hosts file. It accepts connections only from this Mac. If another app holds those ports, it uses 10080 and 10443 and tells you.' },
    ],
  },
  runners: {
    id: 'runners',
    eyebrow: 'Noodle Runners',
    title: 'Your Mac takes your CI jobs.',
    lede: 'Change one line in a workflow. Each job runs on your Mac in a fresh runner, removed afterwards.',
    caption: 'GitHub Actions jobs running on this Mac.',
    alt: 'Noodle Runners: two repos connected, one job running and the last results.',
    stats: [
      { value: '1 line', label: 'to move a job to your Mac', source: 'runs-on: [self-hosted, noodle]' },
      { value: '5 min', label: 'a warm runner waits after each job', source: 'So the next push skips registration' },
    ],
    best: 'iOS and macOS builds on your own Mac.',
    bestText: 'Hosted macOS minutes cost $0.062 a minute. Your Mac already has the Xcode you use.',
    cases: [
      { title: 'Linux tests on arm64', text: 'A fresh container per job. Toolchains and caches stay per repo.', code: 'runs-on: [self-hosted, noodle]' },
      { title: 'Pin an Xcode version', text: 'The macOS runner carries a label for the Xcode on this Mac.', code: 'runs-on: [self-hosted, noodle-macos, xcode-26]' },
      { title: 'Side projects without CI bills', text: 'Private repos run here. Nothing runs while there are no jobs.' },
      { title: 'Jobs that need Apple silicon', text: 'macOS jobs run natively, so Metal and on-device model tests work.' },
    ],
    faq: [
      { q: 'Can I use it on a public repo?', a: 'Not by default. A pull request from a fork could run code on your Mac, so public repos need --allow-public.' },
      { q: 'Is a macOS job sandboxed?', a: 'No. It runs as you, in a fresh folder deleted afterwards. Use it only for repos you trust.' },
      { q: 'Which runner does it use?', a: 'GitHub’s official runner, fresh per job, pinned by version and checksum. One runner per repo stays warm for 5 minutes.' },
    ],
  },
};
