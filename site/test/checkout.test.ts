import { describe, expect, it, vi } from 'vitest';
import { checkout, session, webhook, recover } from '@/lib/checkout';
import { createMail, licenseMail } from '@/lib/mail';
import { fakePay } from '@/lib/fake-pay';
import { entitlement } from '@/lib/entitlement';
import { getCustomer } from '@/lib/license';
import { encodeKey } from '@/lib/keys';
import { fixture } from './helpers';

describe('S6 lifetime checkout', () => {
  it.each([['CN', 'cny'], ['US', 'usd'], [null, 'usd']] as const)('uses visitor country %s independently of language', async (country, currency) => {
    for (const lang of ['zh', 'en']) {
      const { ctx, stripe } = fixture();
      const create = vi.spyOn(stripe.checkout.sessions, 'create');
      const url = await checkout(ctx, 'lifetime', lang, country), params = create.mock.calls[0][0];
      const prefix = lang === 'en' ? '/en' : '';
      expect(url).toContain('/api/fake-pay?session_id=cs_test_');
      expect(params).toMatchObject({ mode: 'payment', currency,
        line_items: [{ price: ctx.env.STRIPE_PRICE_LIFETIME, quantity: 1 }],
        metadata: { plan: 'lifetime' }, allow_promotion_codes: true, customer_creation: 'always',
        payment_intent_data: { metadata: { plan: 'lifetime' } },
        success_url: `${ctx.env.SITE_URL}${prefix}/activated?session_id={CHECKOUT_SESSION_ID}`,
        cancel_url: `${ctx.env.SITE_URL}${prefix}/#pricing` });
      expect(params.integration_identifier).toMatch(/^oilfind-[a-z]{8}$/);
      expect(params).not.toHaveProperty('payment_method_types');
    }
  });
  it('defaults omitted plan to lifetime, rejects other plans before Stripe, and redirects on Stripe failure', async () => {
    const { ctx, stripe } = fixture();
    const create = vi.spyOn(stripe.checkout.sessions, 'create');
    for (const plan of ['', 'annual', 'monthly']) await expect(checkout(ctx, plan, 'en')).rejects.toMatchObject({ code: 'invalid_request' });
    expect(create).not.toHaveBeenCalled();
    await checkout(ctx, null, 'fr');
    expect(create.mock.calls[0][0]).toMatchObject({ metadata: { plan: 'lifetime' }, cancel_url: `${ctx.env.SITE_URL}/#pricing` });
    create.mockRejectedValueOnce(new Error('secret_stripe_failure'));
    vi.spyOn(console, 'error').mockImplementation(() => {});
    expect(await checkout(ctx, 'lifetime', 'en')).toBe(`${ctx.env.SITE_URL}/en/#pricing`);
  });
});

describe('S7 session', () => {
  it('rejects missing, nonexistent, incomplete, unpaid and customerless sessions', async () => {
    const { ctx, stripe } = fixture();
    for (const id of [null, 'bad', 'cs_missing']) await expect(session(ctx, id)).rejects.toMatchObject({ code: 'invalid_request' });
    const url = await checkout(ctx, 'lifetime', 'zh'), id = new URL(url).searchParams.get('session_id')!;
    await expect(session(ctx, id)).rejects.toMatchObject({ code: 'invalid_request' });
    await stripe.completeSession(id); stripe.setSession(id, { payment_status: 'unpaid' });
    await expect(session(ctx, id)).rejects.toMatchObject({ code: 'invalid_request' });
    stripe.setSession(id, { payment_status: 'paid', customer: null });
    await expect(session(ctx, id)).rejects.toMatchObject({ code: 'invalid_request' });
  });
  it('grants lifetime once, preserves devices and returns identical responses', async () => {
    const { ctx, stripe } = fixture(true);
    const id = new URL(await checkout(ctx, 'lifetime', 'en')).searchParams.get('session_id')!;
    const completed = await stripe.completeSession(id), customerID = completed.customer as string;
    await stripe.customers.update(customerID, { metadata: { device_1: 'existing', unrelated: 'keep' } });
    const update = vi.spyOn(stripe.customers, 'update');
    const result = await session(ctx, id);
    expect(result).toEqual({ key: encodeKey(customerID, ctx.env.LICENSE_KEY_SECRET), plan: 'lifetime', email: 'buyer@example.com', mailed: true });
    expect(await session(ctx, id)).toEqual(result);
    expect(update).toHaveBeenCalledTimes(1);
    expect(update).toHaveBeenCalledWith(customerID, { metadata: { lifetime: '1', lifetime_pi: completed.payment_intent, lifetime_paid_at: String(ctx.now()) } });
    expect((await stripe.customers.retrieve(customerID)).metadata?.unrelated).toBe('keep');
    expect(ctx.mail.send).not.toHaveBeenCalled();
  });
  it('accepts no_payment_required and runs lifetime fake payment fulfillment', async () => {
    const { ctx, stripe, send } = fixture(true);
    const id = new URL(await checkout(ctx, 'lifetime', 'en')).searchParams.get('session_id')!;
    expect(await fakePay(ctx, id)).toBe(`${ctx.env.SITE_URL}/en/activated?session_id=${id}`);
    const complete = await stripe.checkout.sessions.retrieve(id);
    stripe.setSession(id, { payment_status: 'no_payment_required' });
    expect((await session(ctx, id)).plan).toBe('lifetime');
    expect((await stripe.customers.retrieve(complete.customer as string)).metadata?.lifetime).toBe('1');
    expect(send).toHaveBeenCalledTimes(1);
    await fakePay(ctx, id); expect(send).toHaveBeenCalledTimes(1);
  });
});

describe('S8 webhook', () => {
  async function purchase(configured = true) {
    const f = fixture(configured), id = new URL(await checkout(f.ctx, 'lifetime', 'zh')).searchParams.get('session_id')!;
    const completed = await f.stripe.completeSession(id);
    const body = JSON.stringify({ type: 'checkout.session.completed', data: { object: completed } });
    const signature = f.stripe.signWebhook(body, f.ctx.env.STRIPE_WEBHOOK_SECRET);
    return { ...f, id, completed, body, signature, customerID: completed.customer as string };
  }
  it('rejects bad signatures and tampered raw bodies', async () => {
    const f = await purchase();
    await expect(webhook(f.ctx, f.body, 'bad')).rejects.toMatchObject({ code: 'invalid_request' });
    await expect(webhook(f.ctx, f.body + ' ', f.signature)).rejects.toMatchObject({ code: 'invalid_request' });
    expect(f.send).not.toHaveBeenCalled();
  });
  it('grants access, sends exact license email and deduplicates event replay and concurrent delivery', async () => {
    const f = await purchase();
    expect(await webhook(f.ctx, f.body, f.signature)).toEqual({ ok: true });
    await Promise.all([webhook(f.ctx, f.body, f.signature), webhook(f.ctx, f.body, f.signature)]);
    expect(f.send).toHaveBeenCalledTimes(1);
    expect(f.send).toHaveBeenCalledWith('buyer@example.com', encodeKey(f.customerID, f.ctx.env.LICENSE_KEY_SECRET), `oilfind-license-${f.id}`);
    const customer = await f.stripe.customers.retrieve(f.customerID);
    expect(customer.metadata).toMatchObject({ lifetime: '1', lifetime_pi: f.completed.payment_intent, [`mailed_${f.id.slice(-12)}`]: '1' });
    expect(licenseMail('OILF-TEST').subject).toBe('你的 Oil Find Pro 授权码 / Your Oil Find Pro license key');
    expect(licenseMail('OILF-TEST').text).toContain('oilfind://activate?key=OILF-TEST');
    expect(licenseMail('OILF-TEST').text).not.toContain('回复这封邮件');
    expect(licenseMail('OILF-TEST', true).text).toContain('直接回复这封邮件');
    expect(licenseMail('OILF-TEST', true).text).toContain('Just reply to this email');
  });
  it('processes async success but waits for a paid status', async () => {
    const f = await purchase();
    for (const payment_status of ['unpaid', 'paid']) {
      const body = JSON.stringify({ type: 'checkout.session.async_payment_succeeded', data: { object: { ...f.completed, payment_status } } });
      await webhook(f.ctx, body, f.stripe.signWebhook(body, f.ctx.env.STRIPE_WEBHOOK_SECRET));
      expect(f.send).toHaveBeenCalledTimes(payment_status === 'paid' ? 1 : 0);
    }
  });
  it('only matching full refunds revoke lifetime; replay and session access cannot grant it again', async () => {
    const f = await purchase();
    await webhook(f.ctx, f.body, f.signature);
    for (const [refunded, payment_intent] of [[false, f.completed.payment_intent], [true, 'pi_other'], [true, f.completed.payment_intent]] as const) {
      const body = JSON.stringify({ type: 'charge.refunded', data: { object: { refunded, payment_intent, customer: f.customerID } } });
      await webhook(f.ctx, body, f.stripe.signWebhook(body, f.ctx.env.STRIPE_WEBHOOK_SECRET));
      expect((await f.stripe.customers.retrieve(f.customerID)).metadata?.lifetime).toBe(refunded && payment_intent === f.completed.payment_intent ? undefined : '1');
    }
    await session(f.ctx, f.id); await webhook(f.ctx, f.body, f.signature);
    await expect(entitlement(await getCustomer(f.ctx, f.customerID))).rejects.toMatchObject({ code: 'inactive' });
  });
  it('mail or metadata failure returns server_error and permits a retry; unknown events do nothing', async () => {
    const f = await purchase();
    vi.spyOn(console, 'error').mockImplementation(() => {});
    f.send.mockRejectedValueOnce(new Error('resend_private_error'));
    await expect(webhook(f.ctx, f.body, f.signature)).rejects.toMatchObject({ code: 'server_error' });
    expect((await f.stripe.customers.retrieve(f.customerID)).metadata?.[`mailed_${f.id.slice(-12)}`]).toBeUndefined();
    await webhook(f.ctx, f.body, f.signature); expect(f.send).toHaveBeenCalledTimes(2);
    const unknown = JSON.stringify({ type: 'customer.created', data: { object: {} } });
    expect(await webhook(f.ctx, unknown, f.stripe.signWebhook(unknown, f.ctx.env.STRIPE_WEBHOOK_SECRET))).toEqual({ ok: true });
    const g = await purchase();
    vi.spyOn(g.stripe.customers, 'update').mockRejectedValueOnce(new Error('stripe_private_error'));
    await expect(webhook(g.ctx, g.body, g.signature)).rejects.toMatchObject({ code: 'server_error' });
    expect(g.send).not.toHaveBeenCalled();
    await webhook(g.ctx, g.body, g.signature); expect(g.send).toHaveBeenCalledTimes(1);
  });
});

describe('S9 recovery and email transport', () => {
  it('requires configured mail; sends only active entitlements and hides absent addresses', async () => {
    const { ctx, stripe, send } = fixture();
    await expect(recover(ctx, { email: 'owner@example.com' })).rejects.toMatchObject({ code: 'email_not_configured' });
    ctx.mail.configured = true;
    stripe.seedCustomer({ email: ' Owner@Example.COM ', plan: 'lifetime' });
    stripe.seedCustomer({ email: 'owner@example.com' });
    stripe.seedCustomer({ email: 'other@example.com', plan: 'lifetime' });
    const list = vi.spyOn(stripe.customers, 'list');
    expect(await recover(ctx, { email: ' OWNER@example.com ' })).toEqual({ ok: true });
    expect(list).toHaveBeenCalledWith({ email: 'owner@example.com', limit: 20 });
    expect(send).toHaveBeenCalledTimes(1);
    expect(send.mock.calls.every(call => call[0] === 'owner@example.com')).toBe(true);
    expect(await recover(ctx, { email: 'missing@example.com' })).toEqual({ ok: true });
    expect(send).toHaveBeenCalledTimes(1);
    for (const input of [{}, { email: 1 }, { email: 'bad' }]) await expect(recover(ctx, input)).rejects.toMatchObject({ code: 'invalid_request' });
  });
  it('uses fetch with the protocol template, sender and idempotency header and propagates failure', async () => {
    const { ctx } = fixture();
    const sendFetch = vi.fn<typeof fetch>().mockResolvedValue(new Response('{}', { status: 200 }));
    const mail = createMail({ ...ctx.env, RESEND_API_KEY: 'resend_fake_test', MAIL_FROM: 'Oil Find <hello@example.com>' }, sendFetch);
    expect(mail.configured).toBe(true);
    await mail.send('owner@example.com', 'OILF-TEST', 'test-session');
    const [url, init] = sendFetch.mock.calls[0];
    expect(url).toBe('https://api.resend.com/emails');
    expect(init?.headers).toMatchObject({ 'Idempotency-Key': 'test-session' });
    expect(JSON.parse(init?.body as string)).toEqual({ from: 'Oil Find <hello@example.com>', to: ['owner@example.com'], ...licenseMail('OILF-TEST') });
    sendFetch.mockResolvedValueOnce(new Response('{}', { status: 500 }));
    await expect(mail.send('owner@example.com', 'OILF-TEST')).rejects.toThrow('email_send_failed');
    sendFetch.mockClear();
    const replyable = createMail({ ...ctx.env, RESEND_API_KEY: 'resend_fake_test', MAIL_FROM: 'Oil Find <hello@example.com>', MAIL_REPLY_TO: 'owner@example.net' }, sendFetch);
    await replyable.send('buyer@example.com', 'OILF-TEST');
    expect(JSON.parse(sendFetch.mock.calls[0][1]?.body as string)).toEqual({ from: 'Oil Find <hello@example.com>', to: ['buyer@example.com'], reply_to: 'owner@example.net', ...licenseMail('OILF-TEST', true) });
    sendFetch.mockClear(); const disabled = createMail(ctx.env, sendFetch);
    expect(disabled.configured).toBe(false); await disabled.send('owner@example.com', 'OILF-TEST'); expect(sendFetch).not.toHaveBeenCalled();
  });
});
