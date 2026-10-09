import type Stripe from 'stripe';
import { NextRequest } from 'next/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import * as context from '@/lib/context';
import * as activateRoute from '@/app/api/activate/route';
import * as refreshRoute from '@/app/api/refresh/route';
import * as deactivateRoute from '@/app/api/deactivate/route';
import * as checkoutRoute from '@/app/api/checkout/route';
import * as sessionRoute from '@/app/api/session/route';
import * as priceRoute from '@/app/api/price/route';
import * as recoverRoute from '@/app/api/recover/route';
import * as webhookRoute from '@/app/api/webhook/route';
import * as fakePayRoute from '@/app/api/fake-pay/route';
import { proxy } from '@/proxy';
import { activate } from '@/lib/license';
import { checkout } from '@/lib/checkout';
import { encodeKey } from '@/lib/keys';
import { DEVICE, fixture, verifiedPayload } from './helpers';

describe('S10 HTTP routes', () => {
  let f: ReturnType<typeof fixture>, key: string, customerID: string;
  const post = (path: string, value: unknown) => new Request(`http://localhost:8787/api/${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(value) });
  beforeEach(() => {
    vi.stubEnv('NODE_ENV', 'test'); vi.stubEnv('STRIPE_FAKE', '1');
    f = fixture(); customerID = f.stripe.seedCustomer({ email: 'dev@example.com', plan: 'lifetime' });
    key = encodeKey(customerID, f.ctx.env.LICENSE_KEY_SECRET);
    vi.spyOn(context, 'getContext').mockReturnValue(f.ctx);
    vi.spyOn(console, 'error').mockImplementation(() => {});
    vi.stubGlobal('fetch', vi.fn(() => { throw new Error('External network forbidden in tests'); }));
  });
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); vi.unstubAllEnvs(); });
  const routes = [
    ['activate', 'POST', activateRoute, activateRoute.POST], ['refresh', 'POST', refreshRoute, refreshRoute.POST],
    ['deactivate', 'POST', deactivateRoute, deactivateRoute.POST], ['checkout', 'GET', checkoutRoute, checkoutRoute.GET],
    ['session', 'GET', sessionRoute, sessionRoute.GET], ['price', 'GET', priceRoute, priceRoute.GET],
    ['recover', 'POST', recoverRoute, recoverRoute.POST], ['webhook', 'POST', webhookRoute, webhookRoute.POST],
    ['fake-pay', 'GET', fakePayRoute, fakePayRoute.GET],
  ] as const;
  it.each(routes)('%s exports only the specified method and directly returns JSON 405/no-store for a wrong method', async (path, method, module, handle) => {
    expect(module.dynamic).toBe('force-dynamic');
    expect(Object.keys(module).sort()).toEqual([method, 'dynamic'].sort());
    const response = await handle(new Request(`http://localhost:8787/api/${path}`, { method: method === 'POST' ? 'GET' : 'POST' }));
    expect(response.status).toBe(405); expect(await response.json()).toEqual({ error: 'method_not_allowed' });
    expect(response.headers.get('Cache-Control')).toBe('no-store');
    expect(response.headers.get('Content-Type')).toBe('application/json; charset=utf-8');
  });
  it.each(routes)('%s proxy rejects every other HTTP method before Next.js automatic handling', async (path, expected) => {
    for (const method of ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS', 'HEAD']) if (method !== expected) {
      const response = proxy(new NextRequest(`http://localhost:8787/api/${path}`, { method }));
      expect(response.status).toBe(405); expect(await response.json()).toEqual({ error: 'method_not_allowed' });
      expect(response.headers.get('Cache-Control')).toBe('no-store');
    }
  });
  it('activation, refresh and deactivation return the protocol objects', async () => {
    const activated = await activateRoute.POST(post('activate', { key: key.toLowerCase(), device: DEVICE, name: 'Test Mac' }));
    expect(activated.status).toBe(200); expect(activated.headers.get('Cache-Control')).toBe('no-store');
    const result = await activated.json();
    expect(result).toMatchObject({ key, plan: 'lifetime', email: 'dev@example.com', devices: 1 });
    expect(verifiedPayload(result.token).dev).toBe(DEVICE);
    const refreshed = await refreshRoute.POST(post('refresh', { key, device: DEVICE }));
    expect(refreshed.status).toBe(200); expect(await refreshed.json()).toEqual(result);
    const deactivated = await deactivateRoute.POST(post('deactivate', { key, device: DEVICE }));
    expect(deactivated.status).toBe(200); expect(await deactivated.json()).toEqual({ ok: true });
    const removed = await refreshRoute.POST(post('refresh', { key, device: DEVICE }));
    expect(removed.status).toBe(410); expect(await removed.json()).toEqual({ error: 'device_removed' });
    for (const response of [refreshed, deactivated, removed]) expect(response.headers.get('Cache-Control')).toBe('no-store');
  });
  it('maps malformed JSON, wrong field types, bad keys, inactive and removed devices to the expected statuses', async () => {
    for (const body of ['{', '[]', 'null', '1']) {
      const response = await activateRoute.POST(new Request('http://localhost/api/activate', { method: 'POST', body }));
      expect(response.status).toBe(400); expect(await response.json()).toEqual({ error: 'invalid_request' });
    }
    const invalid = await activateRoute.POST(post('activate', { key, device: DEVICE.toUpperCase(), name: 'Mac' }));
    expect(invalid.status).toBe(400);
    const badKey = await activateRoute.POST(post('activate', { key: 'bad', device: DEVICE, name: 'Mac' }));
    expect(badKey.status).toBe(403); expect(await badKey.json()).toEqual({ error: 'invalid_key' });
    const inactiveID = f.stripe.seedCustomer({});
    const inactive = await refreshRoute.POST(post('refresh', { key: encodeKey(inactiveID, f.ctx.env.LICENSE_KEY_SECRET), device: DEVICE }));
    expect(inactive.status).toBe(402); expect(await inactive.json()).toEqual({ error: 'inactive' });
  });
  it('returns 303/no-store for checkout and executes fake payment through the same fulfillment path', async () => {
    const response = await checkoutRoute.GET(new Request('http://localhost/api/checkout?lang=en'));
    expect(response.status).toBe(303); expect(response.headers.get('Cache-Control')).toBe('no-store');
    const paymentURL = response.headers.get('Location')!;
    vi.spyOn(context, 'getFakeContext').mockReturnValue(f.ctx);
    const payment = await fakePayRoute.GET(new Request(paymentURL));
    const id = new URL(paymentURL).searchParams.get('session_id')!;
    expect(payment.status).toBe(303); expect(payment.headers.get('Location')).toBe(`http://localhost:8787/en/activated?session_id=${id}`);
    expect(payment.headers.get('Cache-Control')).toBe('no-store');
    const result = await sessionRoute.GET(new Request(`http://localhost/api/session?session_id=${id}`));
    expect(result.status).toBe(200); expect(await result.json()).toMatchObject({ plan: 'lifetime', email: 'buyer@example.com', mailed: false });
    expect(result.headers.get('Cache-Control')).toBe('no-store');
    const invalid = await checkoutRoute.GET(new Request('http://localhost/api/checkout?plan=bad&lang=en'));
    expect(invalid.status).toBe(400); expect(await invalid.json()).toEqual({ error: 'invalid_request' });
    const missing = await sessionRoute.GET(new Request('http://localhost/api/session?session_id=cs_missing'));
    expect(missing.status).toBe(400); expect(await missing.json()).toEqual({ error: 'invalid_request' });
  });
  it.each([['CN', 'cny', 9900, '¥99'], ['US', 'usd', 1999, '$19.99'], [null, 'usd', 1999, '$19.99']] as const)('price and checkout agree for %s without Stripe price lookup', async (country, currency, amount, display) => {
    const headers = country ? { 'x-vercel-ip-country': country } : undefined;
    const response = await priceRoute.GET(new Request('http://localhost/api/price', { headers }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ currency, amount, display });
    expect(response.headers.get('Cache-Control')).toBe('no-store');
    expect(context.getContext).not.toHaveBeenCalled();
    const create = vi.spyOn(f.stripe.checkout.sessions, 'create');
    const checkout = await checkoutRoute.GET(new Request('http://localhost/api/checkout?plan=lifetime&lang=en', { headers }));
    expect(checkout.status).toBe(303);
    expect(create.mock.calls[0][0]).toMatchObject({ currency, line_items: [{ price: f.ctx.env.STRIPE_PRICE_LIFETIME, quantity: 1 }] });
  });
  it('rejects unsupported plans before obtaining context or creating a session', async () => {
    const response = await checkoutRoute.GET(new Request('http://localhost/api/checkout?plan=annual&lang=zh'));
    expect(response.status).toBe(400); expect(await response.json()).toEqual({ error: 'invalid_request' });
    expect(response.headers.get('Cache-Control')).toBe('no-store');
    expect(context.getContext).not.toHaveBeenCalled();
  });
  it('recover returns 501 without mail and 200 with mail, always no-store', async () => {
    const response = await recoverRoute.POST(post('recover', { email: 'dev@example.com' }));
    expect(response.status).toBe(501); expect(await response.json()).toEqual({ error: 'email_not_configured' });
    f.ctx.mail.configured = true;
    const sent = await recoverRoute.POST(post('recover', { email: 'dev@example.com' }));
    expect(sent.status).toBe(200); expect(await sent.json()).toEqual({ ok: true });
    expect(sent.headers.get('Cache-Control')).toBe('no-store'); expect(response.headers.get('Cache-Control')).toBe('no-store');
  });
  it('webhook verifies the exact raw body, returns 400 for bad signatures and 500 for processing failure', async () => {
    const id = new URL(await checkout(f.ctx, 'lifetime', 'zh')).searchParams.get('session_id')!;
    const completed = await f.stripe.completeSession(id);
    const body = JSON.stringify({ type: 'checkout.session.completed', data: { object: completed } }, null, 2) + '\n';
    const signature = f.stripe.signWebhook(body, f.ctx.env.STRIPE_WEBHOOK_SECRET);
    const request = (sig: string) => new Request('http://localhost/api/webhook', { method: 'POST', headers: { 'stripe-signature': sig }, body });
    const construct = vi.spyOn(f.stripe.webhooks, 'constructEvent');
    const bad = await webhookRoute.POST(request('bad'));
    expect(bad.status).toBe(400); expect(await bad.json()).toEqual({ error: 'invalid_request' });
    vi.spyOn(f.stripe.customers, 'update').mockRejectedValueOnce(new Error('Stripe secret stack sk_test_do_not_expose'));
    const failed = await webhookRoute.POST(request(signature));
    expect(failed.status).toBe(500); expect(await failed.json()).toEqual({ error: 'server_error' });
    const valid = await webhookRoute.POST(request(signature));
    expect(valid.status).toBe(200); expect(await valid.json()).toEqual({ ok: true });
    expect(construct).toHaveBeenLastCalledWith(body, signature, f.ctx.env.STRIPE_WEBHOOK_SECRET);
    for (const response of [bad, failed, valid]) expect(response.headers.get('Cache-Control')).toBe('no-store');
    const unknownBody = JSON.stringify({ type: 'unknown.event', data: { object: {} } });
    const unknown = await webhookRoute.POST(new Request('http://localhost/api/webhook', { method: 'POST', headers: { 'stripe-signature': f.stripe.signWebhook(unknownBody, f.ctx.env.STRIPE_WEBHOOK_SECRET) }, body: unknownBody }));
    expect(unknown.status).toBe(200);
  });
  it('contains no Stripe failure detail in the error body or logs', async () => {
    vi.spyOn(f.stripe.customers, 'retrieve').mockRejectedValueOnce(new Error('Stripe private sk_test_secret stack trace'));
    const response = await activateRoute.POST(post('activate', { key, device: DEVICE, name: 'Mac' }));
    expect(response.status).toBe(500); expect(await response.text()).toBe('{"error":"server_error"}');
    expect(response.headers.get('Cache-Control')).toBe('no-store');
    const logged = JSON.stringify(vi.mocked(console.error).mock.calls);
    expect(logged).not.toMatch(/private|sk_test_secret|stack trace/);
    expect(logged).toContain('server_error');
  });
  it('fake payment is 404 without STRIPE_FAKE, without constructing a Stripe client', async () => {
    vi.stubEnv('STRIPE_FAKE', '');
    const response = await fakePayRoute.GET(new Request('http://localhost/api/fake-pay?session_id=cs_fake'));
    expect(response.status).toBe(404); expect(await response.json()).toEqual({ error: 'not_found' });
    expect(response.headers.get('Cache-Control')).toBe('no-store');
    expect(context.getContext).not.toHaveBeenCalled();
  });
});

describe('local context and real SDK adapter without network', () => {
  afterEach(() => { vi.restoreAllMocks(); vi.unstubAllEnvs(); delete globalThis.oilFindFakeStripe; });
  it('adapts lifetime payments and latest charges without network', async () => {
    const retrievePayment = vi.fn().mockResolvedValue({ id: 'pi_test', latest_charge: 'ch_test' });
    const retrieveCharge = vi.fn().mockResolvedValue({ id: 'ch_test', refunded: true, created: 1790000000 });
    const port = context.stripePort({ paymentIntents: { retrieve: retrievePayment }, charges: { retrieve: retrieveCharge } } as unknown as Stripe);
    expect(await port.paymentIntents.retrieve('pi_test')).toEqual({ id: 'pi_test', latest_charge: 'ch_test' });
    expect((await port.charges.retrieve('ch_test')).refunded).toBe(true);
    expect(retrievePayment).toHaveBeenCalledWith('pi_test');
    expect(retrieveCharge).toHaveBeenCalledWith('ch_test');
  });
  it('retains fake singleton data across contexts and disables Resend', async () => {
    delete globalThis.oilFindFakeStripe;
    const log = vi.spyOn(console, 'info').mockImplementation(() => {});
    const now = vi.spyOn(Date, 'now').mockReturnValue(1790000000000);
    const env = fixture().ctx.env;
    for (const [key, value] of Object.entries(env)) vi.stubEnv(key, value);
    vi.stubEnv('RESEND_API_KEY', 'must_never_be_used');
    const first = context.getContext(), second = context.getContext();
    expect(first.stripe).toBe(second.stripe); expect(log).toHaveBeenCalledTimes(1); expect(first.mail.configured).toBe(false);
    const id = (first.stripe as ReturnType<typeof fixture>['stripe']).seedCustomer({ plan: 'lifetime' });
    await activate(first, { key: encodeKey(id, env.LICENSE_KEY_SECRET), device: DEVICE, name: 'Mac' });
    expect((await second.stripe.customers.retrieve(id)).metadata?.device_1).toContain(DEVICE);
    expect(now).toHaveBeenCalled();
  });
  it('production rejects fake payment for every method and never constructs fake or real Stripe', async () => {
    vi.stubEnv('NODE_ENV', 'production'); vi.stubEnv('STRIPE_FAKE', '1');
    delete globalThis.oilFindFakeStripe;
    const real = globalThis.oilFindStripe;
    const env = context.environment({ NODE_ENV: 'production', STRIPE_FAKE: '1' });
    expect(env.STRIPE_FAKE).toBe('');
    expect(env.LICENSE_SIGNING_KEY).toBe(''); expect(env.LICENSE_KEY_SECRET).toBe('');
    expect(env.STRIPE_WEBHOOK_SECRET).toBe(''); expect(env.STRIPE_PRICE_LIFETIME).toBe('');
    expect(context.getFakeContext()).toBeNull();
    expect(() => context.getContext()).toThrowError('not_found');
    for (const method of ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS', 'HEAD']) {
      const response = proxy(new NextRequest('http://localhost/api/fake-pay', { method }));
      expect(response.status).toBe(404); expect(response.headers.get('Cache-Control')).toBe('no-store');
    }
    const response = await fakePayRoute.GET(new Request('http://localhost/api/fake-pay?session_id=cs_fake'));
    expect(response.status).toBe(404); expect(await response.json()).toEqual({ error: 'not_found' });
    const checkout = await checkoutRoute.GET(new Request('http://localhost/api/checkout'));
    expect(checkout.status).toBe(404);
    expect(globalThis.oilFindFakeStripe).toBeUndefined(); expect(globalThis.oilFindStripe).toBe(real);
  });
});
