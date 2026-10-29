import { NextRequest } from 'next/server';
import { unstable_doesMiddlewareMatch } from 'next/experimental/testing/server';
import { describe, expect, it } from 'vitest';
import { config, proxy } from '@/proxy';
import { LANGUAGE_COOKIE } from '@/lib/language';

function request(path: string, language = 'en-US,en;q=0.9', region?: string, agent = 'Mozilla/5.0', cookie?: string) {
  const headers: Record<string, string> = { 'Accept-Language': language, 'User-Agent': agent };
  if (region) headers['x-vercel-ip-country'] = region;
  if (cookie) headers.Cookie = `${LANGUAGE_COOKIE}=${cookie}`;
  return proxy(new NextRequest(`https://find.oiloil.org${path}`, { headers }));
}

describe('visitor language routing', () => {
  it.each(['/', '/pro', '/changelog', '/syntax', '/everything-for-mac', '/privacy'])('redirects only eligible unprefixed pages (%s)', path => {
    expect(unstable_doesMiddlewareMatch({ config, nextConfig: {}, url: path })).toBe(true);
    const response = request(path + '?q=readme');
    expect(response.status).toBe(307);
    expect(response.headers.get('Location')).toBe(`https://find.oiloil.org/en${path === '/' ? '' : path}?q=readme`);
    expect(response.headers.get('Vary')).toContain('Accept-Language');
    expect(response.headers.get('Cache-Control')).toBe('private, no-store');
  });
  it.each(['en-US', 'ja', 'de-DE', 'fr', 'es', 'ko-KR'])('redirects non-Chinese visitors outside Chinese regions (%s)', language => {
    expect(request('/', language, 'US').status).toBe(307);
  });
  it.each(['zh', 'zh-CN', 'zh-TW', 'zh-Hant', 'zh-Hans-CN'])('retains preferred Chinese (%s)', language => {
    expect(request('/', `${language},en;q=0.9`, 'US').status).toBe(200);
  });
  it.each(['CN', 'HK', 'MO', 'TW', 'SG'])('retains every specified region regardless of language (%s)', region => {
    for (const language of ['en-US', 'zh-CN', 'ja']) {
      expect(request('/', language, region).status).toBe(200);
    }
  });
  it.each(['/', '/pro', '/changelog', '/syntax', '/everything-for-mac', '/privacy'])('leaves normal page cache and Vary headers to Next/Vercel (%s)', path => {
    for (const response of [
      request(path, 'zh-CN', 'US'),
      request(path, 'en-US', 'CN'),
      request(path, 'en-US', 'US', 'Googlebot'),
      request(path, 'en-US', 'US', undefined, 'zh'),
    ]) {
      expect(response.status).toBe(200);
      expect(response.headers.get('Cache-Control')).toBeNull();
      expect(response.headers.get('Vary')).toBeNull();
    }
  });
  it('uses quality-weighted preference and leaves missing or wildcard preferences alone', () => {
    expect(request('/', 'en;q=0.5,zh;q=1', 'US').status).toBe(200);
    expect(request('/', 'zh;q=0.5,en;q=1', 'US').status).toBe(307);
    expect(request('/', 'zh;q=0,en;q=0.5', 'US').status).toBe(307);
    for (const language of ['', '*', 'en;q=0', 'en;q=invalid']) expect(request('/', language).status).toBe(200);
    expect(proxy(new NextRequest('https://find.oiloil.org')).status).toBe(200);
  });
  it.each(['GoogleOther', 'Meta-ExternalAgent', 'Meta-ExternalFetcher', 'Googlebot', 'Google-InspectionTool', 'bingbot', 'Baiduspider', 'DuckDuckBot', 'YandexBot', 'Applebot', 'facebookexternalhit', 'Twitterbot', 'LinkedInBot', 'Slackbot-LinkExpanding', 'Discordbot', 'WhatsApp', 'TelegramBot', 'Pinterestbot', 'ClaudeBot', 'GPTBot'])('retains crawler URLs (%s)', agent => {
    expect(request('/', 'en-US', 'US', agent).status).toBe(200);
  });
  it.each(['zh', 'en'])('respects either saved manual choice (%s)', cookie => {
    expect(request('/', 'en-US', 'US', undefined, cookie).status).toBe(200);
  });
  it.each(['/en', '/en/pro', '/en/syntax', '/en/everything-for-mac', '/en/privacy', '/activated', '/recover', '/en/recover', '/sitemap.xml', '/robots.txt', '/assets/icon.png', '/downloads/Oil-Find.zip', '/_next/static/test.js', '/pro/unknown'])('does not process excluded paths (%s)', path => {
    expect(unstable_doesMiddlewareMatch({ config, nextConfig: {}, url: path })).toBe(false);
    expect(request(path).headers.get('Location')).toBeNull();
  });
  it('keeps API behavior and never language-redirects it', () => {
    expect(request('/api/activate').status).toBe(405);
    expect(request('/api/activate').headers.get('Location')).toBeNull();
  });
});
