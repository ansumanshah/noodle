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
  steps: { title: string; text: string }[];
  faq: { q: string; a: string }[];
}

export const pages: Record<Product['id'], ProductPage> = {
  models: {
    id: 'models',
    eyebrow: 'Noodle Models',
    title: 'AI that runs on your Mac.',
    lede: 'Pick a model, press Run, start talking. It works offline after the download and sleeps when you stop.',
    caption: 'Chat with a model on your Mac. Nothing leaves it.',
    alt: 'Noodle Models: a chat with a local model answering on this Mac.',
    stats: [
      { value: '312 ms', label: 'to the first words of a reply', source: 'Long prompt, Qwen3 0.6B GGUF, M4 Mac mini. Ollama decodes 1.3× faster' },
      { value: '0 bytes', label: 'of your chats sent anywhere', source: 'Models run on this Mac' },
    ],
    best: 'Work you cannot send to a cloud tool.',
    bestText: 'Contracts, customer data, unreleased code. Nothing leaves your Mac.',
    cases: [
      { title: 'OpenAI and Anthropic compatible endpoint', text: 'Point scripts, editors and coding tools at a local URL and key. Supports Chat Completions, Responses, Anthropic Messages, embeddings and speech.', code: 'noodle model serve qwen3.5-4b' },
      { title: 'Bring any GGUF or MLX model', text: 'Pick from the curated catalog, or pull weights directly from Hugging Face.', code: 'noodle model pull hf.co/<org>/<repo>' },
      { title: 'Chat with pictures, video and audio', text: 'Drop an image, video or audio clip into the message box when the active model supports it.' },
      { title: 'Ask from anywhere', text: 'Control-Option-Space opens chat from any app. Ask Noodle and Open Noodle Chat also work from Shortcuts and Spotlight.' },
      { title: 'Create images, speech and clips', text: 'The Create tab generates images, spoken audio and short videos directly on this Mac.' },
      { title: 'One-click AI apps', text: 'Install Open WebUI, AnythingLLM or n8n from Apps, pre-wired to your local model.' },
      { title: 'Control memory and disk location', text: 'Auto-unload after 30 seconds, 5 minutes or 1 hour, or store downloads on an external drive.', code: 'noodle model location /Volumes/Fast/models' },
      { title: 'Share on your local network', text: 'Off by default. Turn it on so devices on your network can call your models with an API key.', code: 'noodle model network on' },
    ],
    steps: [
      { title: 'Download Noodle', text: 'Open the app. No account, no terminal.' },
      { title: 'Pick a model', text: 'Choose from the catalog, or bring your own GGUF or MLX file.' },
      { title: 'Chat or connect', text: 'Ask a question in the window, or copy the local endpoint into your editor.' },
    ],
    faq: [
      { q: 'Does it need the internet?', a: 'Only to download a model the first time. After that, chats run with Wi-Fi off.' },
      { q: 'Which models can I run?', a: 'The catalog has small models that fit most Macs, such as Qwen 3.5 4B, Qwen 3.5 2B, Gemma 4 E2B and Qwen3 0.6B, plus models for embeddings, speech, images and video. You can also pull GGUF files from Hugging Face.' },
      { q: 'How do my own apps use it?', a: 'noodle model endpoint prints a local URL, a model ID and a key. Any OpenAI or Anthropic client works with them.' },
      { q: 'Can other devices use my models?', a: 'Only if you turn it on in Settings. Every request needs your key, and the connection is plain HTTP, so use it on a network you trust.' },
      { q: 'Will it slow my Mac down?', a: 'A model uses memory while it runs. When you stop chatting it goes to sleep and returns its memory.' },
    ],
  },
  containers: {
    id: 'containers',
    eyebrow: 'Noodle Containers',
    title: 'Same docker commands. Lighter engine.',
    lede: 'docker, Compose, Buildx and Kubernetes work as they are. One small Linux VM runs them all, and sleeps when nothing is running.',
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
    bestText: 'Web, API, Postgres and Redis from the docker compose up command you already run.',
    cases: [
      { title: 'Switch from Docker Desktop or OrbStack', text: 'Noodle sits beside your current engine as a Docker context. Try it first, then import images and volumes when ready.', code: 'docker context use noodle' },
      { title: 'Builds and multi-arch images', text: 'docker build and Buildx work. amd64 images run through Rosetta.', code: 'docker buildx build --platform linux/amd64 .' },
      { title: 'Single-node Kubernetes', text: 'Start a local k3s cluster on the same engine with pinned manifests.', code: 'noodle kubernetes start' },
      { title: 'Full Linux machines', text: 'Spin up Ubuntu or Alpine Linux VMs with shared folders and shells.', code: 'noodle machine create dev --distro ubuntu' },
      { title: 'Names, not ports', text: 'Open any web container at name.localhost, or name a dev server on your Mac. WebSockets and hot reload work.', code: 'noodle names add api.myapp 3000' },
      { title: 'See inside every container', text: 'Logs, live CPU and memory stats, files and an interactive terminal per container, plus image scans and SBOMs.' },
    ],
    steps: [
      { title: 'Install Noodle', text: 'It adds a noodle Docker context. Your current engine can stay.' },
      { title: 'docker compose up', text: 'The same command, the same compose.yaml. Nothing to rewrite.' },
      { title: 'Open your app', text: 'Each service with a web port answers at a name like web.localhost.' },
    ],
    faq: [
      { q: 'Do my docker commands change?', a: 'No. Noodle adds a Docker context called noodle and speaks the Docker Engine API, so the docker CLI, Compose and Buildx work as they are.' },
      { q: 'Can I keep Docker Desktop or OrbStack?', a: 'Yes. Switch per command with --context, or copy images and volumes over when you are ready.' },
      { q: 'Do I need sudo for .localhost names?', a: 'No. Noodle listens on ports 80 and 443 without root, and edits no hosts file, resolver file or firewall. It accepts connections only from this Mac. If another app holds 80 or 443, it uses 10080 and 10443 and tells you.' },
      { q: 'Do amd64 images work?', a: 'Yes, through Rosetta.' },
      { q: 'How fast is it, really?', a: 'The benchmarks page has every number on one Mac, including the rows where other engines win.' },
    ],
  },
  runners: {
    id: 'runners',
    eyebrow: 'Noodle Runners',
    title: 'Your Mac takes your CI jobs.',
    lede: 'Change one line in a workflow. Its jobs run on your Mac, each on a fresh runner that is removed afterwards.',
    caption: 'GitHub Actions jobs running on this Mac.',
    alt: 'Noodle Runners: two repos connected, one job running and the last results.',
    stats: [
      { value: '1 line', label: 'to move a job to your Mac', source: 'runs-on: [self-hosted, noodle]' },
      { value: '5 min', label: 'a warm runner waits after each job', source: 'So the next push skips registration' },
    ],
    best: 'iOS and macOS builds on your own Mac.',
    bestText: 'Hosted macOS minutes cost $0.062 a minute. Your Mac already has the Xcode you use.',
    cases: [
      { title: 'Linux tests on arm64', text: 'Each job gets a fresh container. Toolchains and caches stay per repo, so the second run skips the toolchain downloads.', code: 'runs-on: [self-hosted, noodle]' },
      { title: 'Pin an Xcode version', text: 'The macOS runner carries an xcode label from the Xcode on this Mac.', code: 'runs-on: [self-hosted, noodle-macos, xcode-26]' },
      { title: 'Side projects without CI bills', text: 'Private repos run here. Nothing runs while you have no jobs.' },
      { title: 'Jobs that need Apple silicon', text: 'macOS jobs run natively, so Metal and on-device model tests work as they do on your Mac.' },
    ],
    steps: [
      { title: 'Sign in to GitHub', text: 'Open Settings > Docker. Noodle reads the token through git and never writes it to a file.' },
      { title: 'Add a repo', text: 'Pick it in the app, or run noodle runners add inside the repo.' },
      { title: 'Change one line and push', text: 'Noodle checks for jobs about every 10 seconds. A push right after a job reuses the warm runner.' },
    ],
    faq: [
      { q: 'Can I use it on a public repo?', a: 'Not by default. A pull request from a fork could run code on your Mac, so Noodle refuses public repos unless you pass --allow-public.' },
      { q: 'Is a macOS job sandboxed?', a: 'No. It runs as you, in a fresh folder that is deleted afterwards. Turn macOS jobs on only for repos you trust.' },
      { q: 'What if my Mac goes to sleep?', a: 'Noodle keeps it awake while a job runs. A laptop with the lid closed still sleeps unless it is on power with an external display.' },
      { q: 'Is it faster than GitHub’s own runner?', a: 'We have not measured it yet. Jobs skip the hosted queue and keep their caches, so time one of your workflows on both.' },
      { q: 'Which runner does it use?', a: 'GitHub’s official runner, one fresh runner per job, pinned by version and checksum. After a job, one runner per repo waits for 5 minutes so the next push skips registration.' },
    ],
  },
};
