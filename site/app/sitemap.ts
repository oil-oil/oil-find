import type { MetadataRoute } from 'next';
import { pagePath } from '@/content/dict';
import { releases } from '@/content/releases';
import { languageAlternates, siteURL } from '@/lib/metadata';

export default function sitemap(): MetadataRoute.Sitemap {
  const lastModified = releases.reduce((latest, release) => release.date > latest ? release.date : latest, releases[0].date);
  return (['home', 'pro', 'changelog'] as const).flatMap(page => (['zh', 'en'] as const).map(lang => ({
    url: siteURL + pagePath(lang, page), lastModified,
    alternates: { languages: languageAlternates(page, true) },
  })));
}
