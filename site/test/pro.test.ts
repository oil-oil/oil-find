import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { afterEach, describe, expect, it, vi } from 'vitest';
import ZhHome from '@/app/(zh)/page';
import EnHome from '@/app/en/page';
import ZhPro, { metadata as zhMetadata } from '@/app/(zh)/pro/page';
import EnPro, { metadata as enMetadata } from '@/app/en/pro/page';
import { TopBar } from '@/components/TopBar';
import { pagePath, proCopy, type Language } from '@/content/dict';
import { GET } from '@/app/api/price/route';
import { loadPriceDisplay } from '@/lib/price';
import specification from './fixtures/m23-copy.json';

// Exact copy is an explicit M23 contract; this fixture comes from the specification tables.
const plain = (s: string) => s.replace(/\*\*/g, '').replace(/\[([^\]]+)\]\([^)]+\)/g, '$1');
function text(html: string) {
  return html.replace(/<[^>]+>/g, '').replace(/&#x27;|&#39;/g, "'").replace(/&quot;/g, '"').replace(/&amp;/g, '&');
}

describe.each(['zh', 'en'] as const)('Pro introduction (%s)', lang => {
  const pages = lang === 'zh' ? [ZhHome, ZhPro] : [EnHome, EnPro];
  it.each(pages)('renders every section copy key through the actual page entry', Page => {
    const html = renderToStaticMarkup(createElement(Page));
    const section = html.match(/<section[^>]*id="pro"[^>]*>([\s\S]*?)<\/section>/)![1];
    const rendered = text(section), expected = specification[lang];
    for (const [key, value] of Object.entries(expected)) {
      if (key === 'faq' || key === '页脚' || key === '顶栏入口') continue;
      for (const part of (value as string).split(' ／ ')) expect(rendered).toContain(plain(part));
    }
    expect(section).toContain('aria-hidden="true"');
    expect(section).toContain(`<mark>${proCopy[lang].query}</mark>`);
    expect(section).toContain(`/api/checkout?plan=lifetime&amp;lang=${lang}`);
    expect(section).toContain('href="/downloads/Oil-Find.zip"');
    expect(html).toContain(`href="${pagePath(lang, 'pro')}"`);
    expect(html).toContain(`href="${pagePath(lang, 'recover')}"`);
    expect(text(html)).toContain(proCopy[lang].recover);
    if (Page === pages[0]) {
      expect(html.indexOf('id="open-source"')).toBeLessThan(html.indexOf('id="pro"'));
      expect(html).toContain('href="#pro"');
    }
  });
  it('renders every FAQ verbatim, localized recovery and metadata', () => {
    const html = renderToStaticMarkup(createElement(pages[1]));
    for (const [q, a] of specification[lang].faq) {
      expect(text(html)).toContain(q); expect(text(html)).toContain(plain(a));
    }
    expect(text(html)).toContain(proCopy[lang].questions);
    expect(html).toContain(`href="${pagePath(lang === 'zh' ? 'en' : 'zh', 'pro')}"`);
    const metadata = lang === 'zh' ? zhMetadata : enMetadata;
    expect(metadata.title).toBe(proCopy[lang].pageTitle);
    expect(metadata.description).toBe(proCopy[lang].description);
    expect(metadata.alternates?.languages).toEqual({ 'zh-CN': '/pro', en: '/en/pro', 'x-default': '/en/pro' });
  });
  it('links to the localized Pro page from other pages', () => {
    for (const page of ['activated', 'recover', 'changelog'] as const) {
      const html = renderToStaticMarkup(createElement(TopBar, { lang, page }));
      expect(html).toContain(`href="${pagePath(lang, 'pro')}"`);
    }
  });
});

describe('regional price loading', () => {
  afterEach(() => vi.unstubAllGlobals());
  it.each(['zh', 'en'] as Language[])('shows an immediate language fallback in server-rendered HTML (%s)', lang => {
    const html = renderToStaticMarkup(createElement(lang === 'zh' ? ZhPro : EnPro));
    expect(text(html)).toContain(lang === 'zh' ? '¥49' : '$9.99');
  });
  it.each([['CN', '¥49'], ['US', '$9.99'], [null, '$9.99']] as const)('uses the API country price independently of language (%s)', async (country, expected) => {
    const fetch = vi.fn(() => GET(new Request('http://localhost/api/price', { headers: country ? { 'x-vercel-ip-country': country } : undefined })));
    vi.stubGlobal('fetch', fetch);
    for (const lang of ['zh', 'en'] as const) expect(await loadPriceDisplay(lang, new AbortController().signal)).toBe(expected);
    expect(fetch).toHaveBeenCalledWith('/api/price', expect.objectContaining({ cache: 'no-store', signal: expect.any(AbortSignal) }));
  });
  it.each(['zh', 'en'] as const)('preserves the fallback on network, HTTP, JSON and invalid-data failures (%s)', async lang => {
    for (const result of [() => Promise.reject(new Error('offline')), () => Promise.resolve(new Response('', { status: 503 })),
      () => Promise.resolve(new Response('{')), () => Promise.resolve(Response.json({ display: '' })), () => Promise.resolve(Response.json(null))]) {
      vi.stubGlobal('fetch', vi.fn(result));
      expect(await loadPriceDisplay(lang, new AbortController().signal)).toBe(lang === 'zh' ? '¥49' : '$9.99');
    }
  });
});
