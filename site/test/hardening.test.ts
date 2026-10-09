import { afterEach, describe, expect, it, vi } from 'vitest';
import { checkout, recover, session, webhook } from '@/lib/checkout';
import { activate, getCustomer, refresh } from '@/lib/license';
import { entitlement } from '@/lib/entitlement';
import { encodeKey } from '@/lib/keys';
import { createMail } from '@/lib/mail';
import * as context from '@/lib/context';
import * as refreshRoute from '@/app/api/refresh/route';
import { DEVICE, fixture, verifiedPayload } from './helpers';

afterEach(() => vi.restoreAllMocks());

async function purchase() {
  const f = fixture(true);
  const id = new URL(await checkout(f.ctx, 'lifetime', 'zh')).searchParams.get('session_id')!;
  const completed = await f.stripe.completeSession(id);
  const customerID = completed.customer as string;
  const paymentID = completed.payment_intent as string;
  const payment = await f.stripe.paymentIntents.retrieve(paymentID);
  const charge = await f.stripe.charges.retrieve(payment.latest_charge as string);
  const deliver = async (type: string, object: unknown) => {
    const body = JSON.stringify({ type, data: { object } });
    return webhook(f.ctx, body, f.stripe.signWebhook(body, f.ctx.env.STRIPE_WEBHOOK_SECRET));
  };
  return { ...f, id, completed, customerID, charge, deliver, key: encodeKey(customerID, f.ctx.env.LICENSE_KEY_SECRET) };
}

describe('M15 S1 refund closure', () => {
  it('refund before completion prevents both webhook and success-page lifetime grants', async () => {
    const f = await purchase();
    await Promise.all([f.deliver('charge.refunded', { ...f.charge, refunded: true }), f.deliver('charge.refunded', { ...f.charge, refunded: true })]);
    const update = vi.spyOn(f.stripe.customers, 'update');
    await f.deliver('checkout.session.completed', f.completed);
    await f.deliver('checkout.session.async_payment_succeeded', f.completed);
    await session(f.ctx, f.id);
    expect((await f.stripe.customers.retrieve(f.customerID)).metadata?.lifetime).toBeUndefined();
    await expect(entitlement(await getCustomer(f.ctx, f.customerID))).rejects.toMatchObject({ code: 'inactive' });
    expect(update).not.toHaveBeenCalled(); expect(f.send).not.toHaveBeenCalled();
  });
  it('checks the latest charge before every grant even when a refund webhook has not arrived', async () => {
    const f = await purchase();
    f.stripe.setCharge(f.charge.id, { refunded: true });
    await session(f.ctx, f.id);
    await f.deliver('checkout.session.completed', f.completed);
    expect((await f.stripe.customers.retrieve(f.customerID)).metadata).toMatchObject({ lifetime_refunded_pi: f.completed.payment_intent });
    expect((await f.stripe.customers.retrieve(f.customerID)).metadata?.lifetime).toBeUndefined();
    expect(f.send).not.toHaveBeenCalled();
  });
  it('partial lifetime refunds leave entitlement unchanged', async () => {
    const f = await purchase();
    await f.deliver('checkout.session.completed', f.completed);
    const before = await f.stripe.customers.retrieve(f.customerID);
    await f.deliver('charge.refunded', { ...f.charge, refunded: false });
    expect(await f.stripe.customers.retrieve(f.customerID)).toEqual(before);
    expect((await entitlement(await getCustomer(f.ctx, f.customerID))).plan).toBe('lifetime');
  });
  it('a full lifetime refund makes refresh return HTTP 402', async () => {
    const f = await purchase();
    await f.deliver('checkout.session.completed', f.completed);
    await activate(f.ctx, { key: f.key, device: DEVICE, name: 'Mac' });
    await f.deliver('charge.refunded', { ...f.charge, refunded: true });
    vi.spyOn(context, 'getContext').mockReturnValue(f.ctx);
    const response = await refreshRoute.POST(new Request('http://localhost/api/refresh', { method: 'POST',
      body: JSON.stringify({ key: f.key, device: DEVICE }) }));
    expect(response.status).toBe(402); expect(await response.json()).toEqual({ error: 'inactive' });
  });
  it('duplicate lifetime refunds are idempotent and preserve a legacy refund plus later refunds', async () => {
    const f = await purchase();
    await f.deliver('checkout.session.completed', f.completed);
    await f.stripe.customers.update(f.customerID, { metadata: { lifetime_refunded_pi: 'pi_legacy' } });
    await f.deliver('charge.refunded', { ...f.charge, refunded: true });
    const before = await f.stripe.customers.retrieve(f.customerID);
    const update = vi.spyOn(f.stripe.customers, 'update');
    await f.deliver('charge.refunded', { ...f.charge, refunded: true });
    expect(await f.stripe.customers.retrieve(f.customerID)).toEqual(before);
    expect(update).not.toHaveBeenCalled();
    expect(before.metadata?.lifetime_refunded_pi).toBe(`pi_legacy,${f.completed.payment_intent}`);
    expect(before.metadata?.lifetime).toBeUndefined();
    await session(f.ctx, f.id);
    expect((await f.stripe.customers.retrieve(f.customerID)).metadata?.lifetime).toBeUndefined();
  });
  it('keeps refund metadata within 500 characters by dropping the oldest records', async () => {
    const f = await purchase();
    const payments = Array.from({ length: 20 }, (_, i) => `pi_${String(i).padStart(25, '0')}`);
    for (const payment_intent of payments) await f.deliver('charge.refunded', { ...f.charge, payment_intent, refunded: true });
    const stored = (await f.stripe.customers.retrieve(f.customerID)).metadata!.lifetime_refunded_pi;
    expect(stored.length).toBeLessThanOrEqual(500);
    expect(stored.split(',')).toEqual(payments.slice(-17));
  });
});

describe('M15 S2 two-stage lifetime tokens', () => {
  it('uses charge completion time, fixes the initial expiry, and becomes permanent after 14 days', async () => {
    const f = await purchase();
    const paidAt = f.charge.created + 86400;
    f.stripe.setCharge(f.charge.id, { created: paidAt }); f.setTime(paidAt);
    await f.deliver('checkout.session.completed', f.completed);
    expect((await f.stripe.customers.retrieve(f.customerID)).metadata?.lifetime_paid_at).toBe(String(paidAt));
    const input = { key: f.key, device: DEVICE, name: 'Mac' };
    expect(verifiedPayload((await activate(f.ctx, input)).token).exp).toBe(paidAt + 21 * 86400);
    f.setTime(paidAt + 13 * 86400);
    expect(verifiedPayload((await refresh(f.ctx, input)).token).exp).toBe(paidAt + 21 * 86400);
    f.setTime(paidAt + 14 * 86400);
    expect(verifiedPayload((await refresh(f.ctx, input)).token).exp).toBe(0);
    f.setTime(paidAt + 15 * 86400);
    expect(verifiedPayload((await refresh(f.ctx, input)).token).exp).toBe(0);
  });
  it('uses session creation when there is no latest charge and preserves old permanent entitlements', async () => {
    const f = await purchase();
    f.stripe.setPaymentIntent(f.completed.payment_intent as string, { latest_charge: null });
    await session(f.ctx, f.id);
    expect((await f.stripe.customers.retrieve(f.customerID)).metadata?.lifetime_paid_at).toBe(String(f.completed.created));
    const id = f.stripe.seedCustomer({ plan: 'lifetime' });
    const result = await activate(f.ctx, { key: encodeKey(id, f.ctx.env.LICENSE_KEY_SECRET), device: DEVICE, name: 'Mac' });
    expect(verifiedPayload(result.token).exp).toBe(0);
  });

});

describe('M15 S3 recovery idempotency', () => {
  it('sends a stable per-customer UTC-hour key through the Resend header', async () => {
    const f = fixture(true);
    const ids = [f.stripe.seedCustomer({ email: 'owner@example.com', plan: 'lifetime' }), f.stripe.seedCustomer({ email: 'owner@example.com', plan: 'lifetime' })];
    const sendFetch = vi.fn<typeof fetch>().mockResolvedValue(new Response('{}', { status: 200 }));
    f.ctx.mail = createMail({ ...f.ctx.env, RESEND_API_KEY: 'test-only' }, sendFetch);
    f.setTime(Date.parse('2026-10-03T15:00:00Z') / 1000);
    expect(await recover(f.ctx, { email: 'owner@example.com' })).toEqual({ ok: true });
    f.advance(3599); await recover(f.ctx, { email: 'owner@example.com' });
    f.advance(1); await recover(f.ctx, { email: 'owner@example.com' });
    expect(sendFetch.mock.calls.map(call => (call[1]?.headers as Record<string, string>)['Idempotency-Key'])).toEqual([
      ...ids.map(id => `oilfind-recover-${id}-2026100315`), ...ids.map(id => `oilfind-recover-${id}-2026100315`),
      ...ids.map(id => `oilfind-recover-${id}-2026100316`),
    ]);
  });
});
