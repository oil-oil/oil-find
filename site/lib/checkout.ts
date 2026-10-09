import { randomBytes } from 'node:crypto';
import { ApiError, logError } from './http';
import { encodeKey } from './keys';
import { getCustomer } from './license';
import { entitlement } from './entitlement';
import { withCustomerLock, writeMetadata } from './devices';
import { visitorPrice } from './price';
import type { Charge, Context, Event, LiveCustomer, Plan, Session } from './types';

export function objectID(value: string | { id: string } | null | undefined): string | null {
  return typeof value === 'string' ? value : value?.id ?? null;
}
function sessionPlan(session: Session): Plan {
  const plan = session.metadata?.plan;
  if (plan !== 'lifetime') throw new ApiError('invalid_request');
  return plan;
}
function paid(session: Session): boolean {
  return session.status === 'complete' && ['paid', 'no_payment_required'].includes(session.payment_status);
}
export async function checkout(ctx: Context, plan: string | null, lang: string | null, country: string | null = null): Promise<string> {
  const prefix = lang === 'en' ? '/en' : '';
  const cancel = `${ctx.env.SITE_URL}${prefix}/#pricing`;
  if (plan !== null && plan !== 'lifetime') throw new ApiError('invalid_request');
  try {
    const suffix = Array.from(randomBytes(8), byte => String.fromCharCode(97 + byte % 26)).join('');
    const session = await ctx.stripe.checkout.sessions.create({
      mode: 'payment', currency: visitorPrice(country).currency,
      line_items: [{ price: ctx.env.STRIPE_PRICE_LIFETIME, quantity: 1 }],
      metadata: { plan: 'lifetime' }, allow_promotion_codes: true,
      integration_identifier: `oilfind-${suffix}`,
      success_url: `${ctx.env.SITE_URL}${prefix}/activated?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: cancel,
      customer_creation: 'always', payment_intent_data: { metadata: { plan: 'lifetime' } },
    });
    if (!session.url) throw new Error();
    return session.url;
  } catch { logError('checkout', 'server_error'); return cancel; }
}
export async function retrieveSession(ctx: Context, id: string | null): Promise<Session> {
  if (!id || !/^cs_[A-Za-z0-9_]+$/.test(id)) throw new ApiError('invalid_request');
  try { return await ctx.stripe.checkout.sessions.retrieve(id); }
  catch (error) {
    if ((error as { statusCode?: number })?.statusCode === 404) throw new ApiError('invalid_request');
    throw error;
  }
}
function refundedPayments(customer: LiveCustomer): string[] {
  return (customer.metadata.lifetime_refunded_pi ?? '').split(',').filter(Boolean);
}
async function recordRefund(ctx: Context, customer: LiveCustomer, paymentIntent: string): Promise<void> {
  const payments = [...new Set([...refundedPayments(customer), paymentIntent])];
  while (payments.join(',').length > 500) payments.shift();
  await writeMetadata(ctx, customer.id, customer.metadata, {
    lifetime_refunded_pi: payments.join(','),
    ...(customer.metadata.lifetime_pi === paymentIntent ? { lifetime: '' } : {}),
  });
}
export async function grantLifetime(ctx: Context, customer: LiveCustomer, session: Session): Promise<boolean> {
  const paymentIntent = objectID(session.payment_intent) ?? '';
  // A refunded Checkout URL or replayed completion must not restore lifetime access.
  if (paymentIntent && refundedPayments(customer).includes(paymentIntent)) return false;
  const payment = paymentIntent ? await ctx.stripe.paymentIntents.retrieve(paymentIntent) : null;
  const charge = typeof payment?.latest_charge === 'string'
    ? await ctx.stripe.charges.retrieve(payment.latest_charge) : payment?.latest_charge;
  if (charge?.refunded === true && paymentIntent) {
    await recordRefund(ctx, customer, paymentIntent); return false;
  }
  const paidAt = charge?.created ?? session.created;
  await writeMetadata(ctx, customer.id, customer.metadata, {
    lifetime: '1', lifetime_pi: paymentIntent, lifetime_paid_at: String(paidAt),
  });
  return true;
}
export async function session(ctx: Context, id: string | null) {
  const result = await retrieveSession(ctx, id);
  const customerID = objectID(result.customer);
  if (!paid(result) || !customerID) throw new ApiError('invalid_request');
  const plan = sessionPlan(result);
  return withCustomerLock(ctx, customerID, async () => {
    const customer = await getCustomer(ctx, customerID);
    await grantLifetime(ctx, customer, result);
    return { key: encodeKey(customerID, ctx.env.LICENSE_KEY_SECRET), plan, email: customer.email ?? '', mailed: ctx.mail.configured };
  });
}
export async function fulfillSession(ctx: Context, result: Session): Promise<void> {
  if (!paid(result)) return;
  const customerID = objectID(result.customer);
  if (!customerID) throw new ApiError('invalid_request');
  sessionPlan(result);
  await withCustomerLock(ctx, customerID, async () => {
    const customer = await getCustomer(ctx, customerID);
    if (!await grantLifetime(ctx, customer, result)) return;
    const marker = `mailed_${result.id.slice(-12)}`;
    if (ctx.mail.configured && customer.email && customer.metadata[marker] !== '1') {
      await ctx.mail.send(customer.email, encodeKey(customerID, ctx.env.LICENSE_KEY_SECRET), `oilfind-license-${result.id}`);
      await writeMetadata(ctx, customerID, customer.metadata, { [marker]: '1' });
    }
  });
}
export async function webhook(ctx: Context, body: string, signature: string | null) {
  let event: Event;
  try { event = ctx.stripe.webhooks.constructEvent(body, signature ?? '', ctx.env.STRIPE_WEBHOOK_SECRET); }
  catch { throw new ApiError('invalid_request'); }
  try {
    if (['checkout.session.completed', 'checkout.session.async_payment_succeeded'].includes(event.type)) {
      await fulfillSession(ctx, event.data.object as Session);
    } else if (event.type === 'charge.refunded') {
      const charge = event.data.object as Charge;
      const customerID = objectID(charge.customer), pi = objectID(charge.payment_intent);
      if (charge.refunded === true && customerID && pi) {
        await withCustomerLock(ctx, customerID, async () => {
          await recordRefund(ctx, await getCustomer(ctx, customerID), pi);
        });
      }
    }
    return { ok: true };
  } catch { logError(event.type, 'server_error'); throw new ApiError('server_error'); }
}
export async function recover(ctx: Context, input: Record<string, unknown>) {
  if (typeof input.email !== 'string' || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(input.email.trim())) throw new ApiError('invalid_request');
  if (!ctx.mail.configured) throw new ApiError('email_not_configured');
  const email = input.email.trim().toLowerCase();
  const { data } = await ctx.stripe.customers.list({ email, limit: 20 });
  for (const item of data) {
    if (item.deleted || item.email?.trim().toLowerCase() !== email) continue;
    const customer = { ...item, metadata: { ...item.metadata } };
    try { await entitlement(customer); }
    catch (error) { if (error instanceof ApiError && error.code === 'inactive') continue; throw error; }
    const hour = new Date(ctx.now() * 1000).toISOString().slice(0, 13).replace(/[-T]/g, '');
    await ctx.mail.send(email, encodeKey(customer.id, ctx.env.LICENSE_KEY_SECRET), `oilfind-recover-${customer.id}-${hour}`);
  }
  return { ok: true };
}
