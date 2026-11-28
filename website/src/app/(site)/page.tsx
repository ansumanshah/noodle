import type { Metadata } from 'next';
import { Hero } from '@/components/landing/Hero';
import {
  BeforeYouInstall,
  ClosingCta,
  ContainersSection,
  ModelsSection,
  RunnersSection,
} from '@/components/landing/Sections';

export const metadata: Metadata = {
  title: { absolute: 'Noodle: local AI, containers and CI runners on your Mac' },
  alternates: { canonical: '/' },
};

export default function Home() {
  return (
    <>
      <Hero />
      <ModelsSection />
      <ContainersSection />
      <RunnersSection />
      <BeforeYouInstall />
      <ClosingCta />
    </>
  );
}
