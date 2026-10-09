import type { Metadata } from 'next';
import { activatedCopy, commonCopy, dict, pagePath, proCopy, recoverCopy, type Language, type SitePage } from '@/content/dict';
import { changelogTitle } from '@/content/releases';

export const siteURL = 'https://find.oiloil.org';

export function languageAlternates(page: SitePage, absolute = false) {
  const prefix = absolute ? siteURL : '';
  return { 'zh-CN': prefix + pagePath('zh', page), en: prefix + pagePath('en', page), 'x-default': prefix + pagePath('en', page) };
}

export function siteMetadata(lang: Language, page: SitePage = 'home'): Metadata {
  const hidden = page === 'activated' || page === 'recover';
  const title = page === 'home' ? dict[lang].title : page === 'pro' ? proCopy[lang].pageTitle : page === 'activated' ? activatedCopy[lang].title : page === 'recover' ? recoverCopy[lang].title : `${changelogTitle[lang]} · Oil Find`;
  const description = page === 'home' ? dict[lang].description : page === 'pro' ? proCopy[lang].description : page === 'changelog' ? (lang === 'zh' ? 'Oil Find 每个版本的更新内容。' : 'What changed in each version of Oil Find.') : null;
  const image = { url: `/assets/og/${page === 'pro' ? 'pro' : 'home'}.${lang}.png`, width: 1200, height: 630, alt: page === 'pro' ? proCopy[lang].pageTitle : dict[lang].title };
  return {
    metadataBase: new URL(siteURL),
    title,
    description,
    robots: hidden ? { index: false, follow: true } : { index: true, follow: true },
    alternates: hidden ? null : { canonical: pagePath(lang, page), languages: languageAlternates(page) },
    openGraph: hidden ? null : {
      type: 'website', siteName: commonCopy.brand, title, description: description!, url: pagePath(lang, page),
      locale: lang === 'zh' ? 'zh_CN' : 'en_US', alternateLocale: lang === 'zh' ? 'en_US' : 'zh_CN', images: [image],
    },
    twitter: hidden ? null : { card: 'summary_large_image', title, description: description!, images: [image] },
  };
}
