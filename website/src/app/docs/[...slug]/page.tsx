import { source } from '@/lib/source';
import { DocsLayout } from 'fumadocs-ui/layouts/docs';
import { DocsBody, DocsDescription, DocsPage, DocsTitle, MarkdownCopyButton } from 'fumadocs-ui/layouts/docs/page';
import { notFound } from 'next/navigation';
import { getMDXComponents } from '@/components/mdx';
import { Mark } from '@/components/ui/Mark';
import { Provider } from '@/components/provider';
import type { Metadata } from 'next';
import { createRelativeLink } from 'fumadocs-ui/mdx';

// The docs sidebar layout is rendered here, not in a layout file, so /docs/ (the docs home)
// can use the site header instead.
export default async function Page(props: PageProps<'/docs/[...slug]'>) {
  const { slug } = await props.params;
  const page = source.getPage(slug);
  if (!page) notFound();

  const MDX = page.data.body;

  return (
    <Provider>
    <DocsLayout
      tree={source.getPageTree()}
      nav={{
        title: (
          <span className="flex items-center gap-2 font-semibold">
            <Mark size={24} />
            Noodle Docs
          </span>
        ),
        url: '/docs/',
      }}
      links={[
        { text: 'Home', url: '/' },
        { text: 'Benchmarks', url: '/benchmarks/resources/' },
        { text: 'Releases', url: '/releases/' },
      ]}
    >
      <DocsPage toc={page.data.toc} full={page.data.full}>
        <DocsTitle>{page.data.title}</DocsTitle>
        <DocsDescription className="mb-0">{page.data.description}</DocsDescription>
        <div className="flex flex-row items-center gap-2 border-b pb-6">
          <MarkdownCopyButton markdownUrl={`/llms.mdx${page.url}.md`} />
        </div>
        <DocsBody>
          <MDX components={getMDXComponents({ a: createRelativeLink(source, page) })} />
        </DocsBody>
      </DocsPage>
    </DocsLayout>
    </Provider>
  );
}

export async function generateStaticParams() {
  return source.generateParams();
}

export async function generateMetadata(props: PageProps<'/docs/[...slug]'>): Promise<Metadata> {
  const { slug } = await props.params;
  const page = source.getPage(slug);
  if (!page) notFound();
  return {
    title: page.data.title,
    description: page.data.description,
    alternates: { canonical: `${page.url}/` },
  };
}
