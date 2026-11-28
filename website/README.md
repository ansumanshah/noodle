# Noodle website

Next.js 16 static export with Fumadocs 16, Tailwind 4 and Motion. This is the Noodle website.

## Build and preview

Use Node 22.23.4 or newer and Bun.

```sh
cd website
bun install --frozen-lockfile
bun run build      # next build, then scripts/postbuild.mjs
bun run size       # gzip size of what each page loads; fails if the landing page tops 150 KB
bun run typecheck
bun run lint
bun run serve      # wrangler pages dev out, applies _headers and _redirects like Cloudflare Pages
```

Deploy `website/out`, or set the Pages project root to `website`, the build command to `bun run build` and the output directory to `out`.

## Layout

- `content/docs/` is the docs. `containers/` and `models/` are root folders, so each is a sidebar tab. `(reference)/` adds no URL segment and holds install, CLI, agents, security, troubleshooting and benchmarks. Add a page by adding an `.mdx` file with `title` and `description`, then list it in the folder's `meta.json`.
- `src/app/(site)/` is the landing page, benchmarks, releases and licences. `src/app/docs/page.tsx` is the docs home. `src/app/docs/[...slug]/page.tsx` renders every docs page.
- `src/lib/site.ts` holds shared facts: the three products and their links, the release state and the GitHub repository.
- `src/components/` is organised by surface: `landing/`, `site/`, `docs/`, `ui/`.
- `scripts/postbuild.mjs` adds the per-page script-hash CSP, copies `_headers` and `_redirects` and writes `/docs/<page>.md`.
- `public/data/` is the benchmark JSON the landing page and `/benchmarks/resources/` read at build time. `public/assets/` is the real app screenshots.

## Release state

`siteConfig.release` in `src/lib/site.ts` holds `{ version, url }` for the current release; the DMG is attached to the GitHub release of the same tag. Bump both for each release. `siteConfig.repo` is the public `owner/repo` linked from the header and hero. Add an item to `src/app/releases.xml/route.ts` with the release.

## Agent surfaces

`/llms.txt`, `/llms-full.txt`, `/llms.mdx/docs/<page>.md` and `/docs/<page>.md` are generated at build time. `/docs/agents/` documents the CLI, the Docker socket and the model endpoint.

## Licences

`scripts/gen-notice.sh` writes `src/generated/third-party-table.html` and `public/THIRD_PARTY_NOTICES.txt` from `docs/third-party.json` and checks `website/bun.lock` against it. Run it after any dependency change.
