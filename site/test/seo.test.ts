import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { metadata as zhHome } from '@/app/(zh)/layout';
import { metadata as enHome } from '@/app/en/layout';
import { metadata as zhPro } from '@/app/(zh)/pro/page';
import { metadata as enPro } from '@/app/en/pro/page';
import { metadata as zhChangelog } from '@/app/(zh)/changelog/page';
import { metadata as enChangelog } from '@/app/en/changelog/page';
import { metadata as zhActivated } from '@/app/(zh)/activated/page';
import { metadata as enActivated } from '@/app/en/activated/page';
import { metadata as zhRecover } from '@/app/(zh)/recover/page';
import { metadata as enRecover } from '@/app/en/recover/page';
import sitemap from '@/app/sitemap';
import robots from '@/app/robots';
import { Landing } from '@/components/Landing';
import { Pro } from '@/components/Pro';
import { footerQuestions, pagePath, proCopy } from '@/content/dict';
import { releases } from '@/content/releases';
import { siteURL } from '@/lib/metadata';
import { serializeStructuredData } from '@/lib/structured-data';
import specification from './fixtures/m24-copy.json';

// Verbatim copy is an explicit M24 contract; this fixture comes from its tables.
const pages = [
  ['/', zhHome, 'zh', 'home'], ['/en', enHome, 'en', 'home'],
  ['/pro', zhPro, 'zh', 'pro'], ['/en/pro', enPro, 'en', 'pro'],
  ['/changelog', zhChangelog, 'zh', 'changelog'], ['/en/changelog', enChangelog, 'en', 'changelog'],
] as const;

it.each(pages)('provides the specified metadata through the route entry (%s)', (path, metadata, lang, page) => {
  const copy = specification.metadata[path];
  expect(metadata.title).toBe(copy.title);
  expect(metadata.description).toBe(copy.description);
  expect(metadata.metadataBase?.toString()).toBe(siteURL + '/');
  expect(metadata.alternates).toEqual({ canonical: path, languages: {
    'zh-CN': pagePath('zh', page), en: pagePath('en', page), 'x-default': pagePath('en', page),
  } });
  expect(metadata.robots).toEqual({ index: true, follow: true });
  const image = `/assets/og/${page === 'pro' ? 'pro' : 'home'}.${lang}.png`;
  expect(metadata.openGraph).toMatchObject({ title: copy.title, description: copy.description, url: path,
    locale: lang === 'zh' ? 'zh_CN' : 'en_US', images: [{ url: image, width: 1200, height: 630 }] });
  expect(metadata.twitter).toMatchObject({ card: 'summary_large_image', title: copy.title, description: copy.description, images: [{ url: image }] });
  const png = readFileSync(new URL('../public' + image, import.meta.url));
  expect(png.subarray(1, 4).toString()).toBe('PNG');
  expect([png.readUInt32BE(16), png.readUInt32BE(20)]).toEqual([1200, 630]);
});

it.each([zhActivated, enActivated, zhRecover, enRecover])('prevents indexing and clears inherited home metadata', metadata => {
  expect(metadata.robots).toEqual({ index: false, follow: true });
  for (const field of ['description', 'alternates', 'openGraph', 'twitter'] as const) expect(metadata[field]).toBeNull();
});

it('lists only the six public URLs, with release date and reciprocal languages', () => {
  const entries = sitemap();
  expect(entries.map(entry => entry.url).sort()).toEqual(pages.map(([path]) => siteURL + path).sort());
  const latestDate = releases.map(release => release.date).sort().at(-1);
  for (const [path, , , page] of pages) {
    expect(entries.find(entry => entry.url === siteURL + path)).toEqual({
      url: siteURL + path, lastModified: latestDate, alternates: { languages: {
        'zh-CN': siteURL + pagePath('zh', page), en: siteURL + pagePath('en', page), 'x-default': siteURL + pagePath('en', page),
      } },
    });
  }
  expect(robots()).toEqual({ rules: { userAgent: '*', allow: '/', disallow: '/api/' }, sitemap: siteURL + '/sitemap.xml' });
});

describe.each(['zh', 'en'] as const)('rendered structured data (%s)', lang => {
  function render(page: 'home' | 'pro') {
    const html = renderToStaticMarkup(createElement(page === 'home' ? Landing : Pro, { lang }));
    const matches = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)];
    expect(matches).toHaveLength(1);
    return { html, schema: JSON.parse(matches[0][1]) };
  }
  it('marks up the app with current release, download and localized free/Pro offers', () => {
    const { schema } = render('home');
    expect(schema['@context']).toBe('https://schema.org');
    const app = schema['@graph'].find((entity: { '@type': string }) => entity['@type'] === 'SoftwareApplication');
    expect(app).toMatchObject({ name: 'Oil Find', operatingSystem: 'macOS 14+', applicationCategory: 'UtilitiesApplication',
      softwareVersion: releases[0].version, downloadUrl: siteURL + '/downloads/Oil-Find.zip', image: siteURL + '/assets/icon.png' });
    expect(app.offers).toMatchObject([
      { '@type': 'Offer', price: 0, priceCurrency: lang === 'zh' ? 'CNY' : 'USD' },
      { '@type': 'Offer', price: lang === 'zh' ? 49 : 9.99, priceCurrency: lang === 'zh' ? 'CNY' : 'USD', url: siteURL + pagePath(lang, 'pro') },
    ]);
  });
  it('renders the two verbatim footer questions first and uses all visible answers in the home FAQ', () => {
    expect(footerQuestions(lang).slice(0, 2)).toEqual(specification.faq[lang]);
    const { html, schema } = render('home');
    const footer = html.slice(html.indexOf('<footer'));
    const faq = schema['@graph'].find((entity: { '@type': string }) => entity['@type'] === 'FAQPage');
    expect(faq.mainEntity).toEqual(footerQuestions(lang).map(({ q, a }) => ({ '@type': 'Question', name: q, acceptedAnswer: { '@type': 'Answer', text: a } })));
    for (const item of footerQuestions(lang)) {
      expect(footer).toContain(renderToStaticMarkup(createElement('b', null, item.q)));
      expect(footer).toContain(renderToStaticMarkup(createElement('span', null, item.a)));
    }
    expect(footer.indexOf(specification.faq[lang][0].q)).toBeLessThan(footer.indexOf(specification.faq[lang][1].q));
    expect(footer.indexOf(specification.faq[lang][1].q)).toBeLessThan(footer.indexOf(footerQuestions(lang)[2].q));
  });
  it('uses existing visible Pro FAQs, without markdown link syntax', () => {
    const { html, schema } = render('pro');
    expect(schema['@type']).toBe('FAQPage');
    expect(schema.mainEntity).toEqual(proCopy[lang].faq.map(({ q, a }) => ({ '@type': 'Question', name: q,
      acceptedAnswer: { '@type': 'Answer', text: a.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1') } })));
    for (const { q } of proCopy[lang].faq) expect(html).toContain(q);
  });
});

it('keeps script-closing content inert and preserves JSON data', () => {
  const input = { text: '</script><script>alert(1)</script>' };
  const serialized = serializeStructuredData(input);
  expect(serialized).not.toContain('<');
  expect(JSON.parse(serialized)).toEqual(input);
});
