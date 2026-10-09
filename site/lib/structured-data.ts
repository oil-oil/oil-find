import { dict, footerQuestions, pagePath, proCopy, type Language } from '@/content/dict';
import { releases } from '@/content/releases';
import { siteURL } from './metadata';

export function faqSchema(questions: { q: string; a: string }[]) {
  return {
    '@type': 'FAQPage',
    mainEntity: questions.map(({ q, a }) => ({
      '@type': 'Question', name: q,
      acceptedAnswer: { '@type': 'Answer', text: a.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1') },
    })),
  };
}

export function pageStructuredData(lang: Language, page: 'home' | 'pro') {
  if (page === 'pro') return { '@context': 'https://schema.org', ...faqSchema(proCopy[lang].faq) };
  return {
    '@context': 'https://schema.org',
    '@graph': [
      {
        '@type': 'SoftwareApplication', name: 'Oil Find', description: dict[lang].description,
        url: siteURL + pagePath(lang), operatingSystem: 'macOS 14+', applicationCategory: 'UtilitiesApplication',
        downloadUrl: `${siteURL}/downloads/Oil-Find.zip`, softwareVersion: releases[0].version,
        image: `${siteURL}/assets/icon.png`,
        offers: [
          { '@type': 'Offer', name: lang === 'zh' ? 'Oil Find 免费版' : 'Oil Find Free', price: 0, priceCurrency: lang === 'zh' ? 'CNY' : 'USD', url: `${siteURL}/downloads/Oil-Find.zip` },
          { '@type': 'Offer', name: 'Oil Find Pro', price: lang === 'zh' ? 49 : 9.99, priceCurrency: lang === 'zh' ? 'CNY' : 'USD', url: siteURL + pagePath(lang, 'pro') },
        ],
      },
      faqSchema(footerQuestions(lang)),
    ],
  };
}

export function serializeStructuredData(data: unknown): string {
  return JSON.stringify(data).replace(/</g, '\\u003c');
}
