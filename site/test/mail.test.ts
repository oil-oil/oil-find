import { describe, expect, it, vi } from 'vitest';
import { createMail, licenseMail } from '@/lib/mail';
import { fixture } from './helpers';

const KEY = 'OILF-7Q2M-9XHT-A4KD-6N8P-R3YC-B5VF-T2ZG';

describe('license email', () => {
  it('sends both readable HTML and the Pro plain text with the same activation key', async () => {
    const { ctx } = fixture();
    const sendFetch = vi.fn<typeof fetch>().mockResolvedValue(new Response('{}', { status: 200 }));
    const mail = createMail({ ...ctx.env, RESEND_API_KEY: 'resend_fake_test', MAIL_FROM: 'Oil Find <hello@example.com>' }, sendFetch);
    await mail.send('buyer@example.com', KEY, 'license-mail-test');
    const body = JSON.parse(sendFetch.mock.calls[0][1]?.body as string);
    expect(body.subject).toBe('你的 Oil Find Pro 授权码 / Your Oil Find Pro license key');
    for (const content of [body.text, body.html]) {
      expect(content).toContain('感谢购买 Oil Find Pro。');
      expect(content).toContain('Thanks for buying Oil Find Pro.');
    }
    expect(body.text).toContain(`授权码：${KEY}`);
    expect(body.text).toContain(`License key: ${KEY}`);
    expect(body.html).toContain(`href="oilfind://activate?key=${KEY}"`);
    expect(body.html).toContain('设置里的 Pro 分区');
    expect(body.html).toContain('Pro section of Oil Find’s settings');
    expect(body.html).not.toContain('<script');
    expect(body.html).not.toContain('<link');
    // Soft breaks do not change the key's text when copied from the email.
    const code = body.html.match(/<code[^>]*>(.*?)<\/code>/s)?.[1];
    expect(code?.replaceAll('<wbr>', '')).toBe(KEY);
  });

  it('escapes text and URL attributes instead of rendering key input as markup', () => {
    const input = 'OILF-<img src=x onerror="alert(1)">&\'';
    const { html } = licenseMail(input);
    expect(html).toContain('&lt;img src=x onerror=&quot;alert(1)&quot;&gt;&amp;&#39;');
    expect(html).not.toContain('<img src=x');
    expect(html).toContain(`href="oilfind://activate?key=${encodeURIComponent(input).replaceAll("'", '&#39;')}"`);
  });

  it('only offers a reply when reply-to is configured, in both versions', () => {
    for (const enabled of [false, true]) {
      const mail = licenseMail(KEY, enabled);
      for (const body of [mail.text, mail.html]) {
        expect(body.includes('直接回复这封邮件')).toBe(enabled);
        expect(body.includes('Just reply to this email')).toBe(enabled);
      }
    }
  });
});
