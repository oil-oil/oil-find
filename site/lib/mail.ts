import type { Env, Mail } from './types';
import { licenseEmailHTML } from './license-email';

export function licenseMail(key: string, replyable = false) {
  const link = `oilfind://activate?key=${key}`;
  const zhReply = replyable ? '\n有问题，或 14 天内需要退款，直接回复这封邮件。' : '';
  const enReply = replyable ? '\nQuestions, or a refund within 14 days? Just reply to this email.' : '';
  return { subject: '你的 Oil Find Pro 授权码 / Your Oil Find Pro license key', text: `感谢购买 Oil Find Pro。

授权码：${key}

在装好 Oil Find 的 Mac 上点这个链接就能激活：
${link}

也可以把授权码粘贴到 Oil Find 设置里的 Pro 分区。
一个授权可以在 3 台 Mac 上使用。${zhReply}

————

Thanks for buying Oil Find Pro.

License key: ${key}

Open this link on a Mac with Oil Find installed to activate:
${link}

You can also paste the key into the Pro section of Oil Find’s settings.
One license works on up to 3 Macs.${enReply}`, html: licenseEmailHTML(key, replyable) };
}
export function createMail(env: Env, sendFetch: typeof fetch = fetch): Mail {
  return {
    configured: Boolean(env.RESEND_API_KEY),
    async send(email, key, idempotencyKey) {
      if (!env.RESEND_API_KEY) return;
      const response = await sendFetch('https://api.resend.com/emails', {
        method: 'POST', headers: { Authorization: `Bearer ${env.RESEND_API_KEY}`, 'Content-Type': 'application/json',
          ...(idempotencyKey ? { 'Idempotency-Key': idempotencyKey } : {}) },
        body: JSON.stringify({ from: env.MAIL_FROM, to: [email],
          ...(env.MAIL_REPLY_TO ? { reply_to: env.MAIL_REPLY_TO } : {}), ...licenseMail(key, Boolean(env.MAIL_REPLY_TO)) }),
      });
      if (!response.ok) throw new Error('email_send_failed');
    },
  };
}
