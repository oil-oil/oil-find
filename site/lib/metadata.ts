import type { Metadata } from 'next';
import { activatedCopy, commonCopy, dict, pagePath, recoverCopy, type Language, type SitePage } from '@/content/dict';
import { changelogTitle } from '@/content/releases';

const siteURL = 'https://find.oiloil.org';

export function siteMetadata(lang: Language, page: SitePage = 'home'): Metadata {
  const home = page === 'home';
  return {
    metadataBase: new URL(siteURL),
    title: home ? dict[lang].title : page === 'activated' ? activatedCopy[lang].title : page === 'recover' ? recoverCopy[lang].title : changelogTitle[lang],
    description: home ? dict[lang].description : undefined,
    openGraph: home ? { title: commonCopy.brand, description: commonCopy.ogDescription, images: ['/assets/icon.png'] } : null,
    alternates: { languages: { 'zh-CN': pagePath('zh', page), en: pagePath('en', page) } },
  };
}
