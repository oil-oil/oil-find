import Stripe from 'stripe';
import { createFakeStripe, type FakeStripe } from './fake-stripe';
import { createMail } from './mail';
import { encodeKey } from './keys';
import { ApiError } from './http';
import type { Context, Env, StripePort } from './types';

declare global {
  var oilFindFakeStripe: FakeStripe | undefined;
  var oilFindStripe: { secret: string; port: StripePort } | undefined;
}
export function environment(source: Record<string, string | undefined>): Env {
  const fake = source.STRIPE_FAKE === '1' && source.NODE_ENV !== 'production';
  return {
    STRIPE_SECRET_KEY: source.STRIPE_SECRET_KEY ?? '',
    STRIPE_WEBHOOK_SECRET: source.STRIPE_WEBHOOK_SECRET || (fake ? 'whsec_local_fake' : ''),
    STRIPE_PRICE_LIFETIME: source.STRIPE_PRICE_LIFETIME || (fake ? 'price_fake_lifetime' : ''),
    LICENSE_SIGNING_KEY: source.LICENSE_SIGNING_KEY || (fake ? Buffer.alloc(32, 1).toString('base64') : ''),
    LICENSE_KEY_SECRET: source.LICENSE_KEY_SECRET || (fake ? Buffer.alloc(32, 2).toString('base64') : ''),
    SITE_URL: (source.SITE_URL || 'http://localhost:8787').replace(/\/+$/, ''),
    // Fake mode cannot send external email, even if local secrets are configured.
    RESEND_API_KEY: fake ? '' : source.RESEND_API_KEY ?? '',
    MAIL_FROM: source.MAIL_FROM ?? '', MAIL_REPLY_TO: source.MAIL_REPLY_TO ?? '', STRIPE_FAKE: fake ? '1' : '',
  };
}
export function stripePort(client: Stripe): StripePort {
  const customer = (item: Stripe.Customer | Stripe.DeletedCustomer) => item.deleted
    ? { id: item.id, deleted: true }
    : { id: item.id, email: item.email, metadata: item.metadata };
  return {
    customers: {
      retrieve: async id => customer(await client.customers.retrieve(id)),
      update: async (id, params) => customer(await client.customers.update(id, params)),
      list: async params => ({ data: (await client.customers.list(params)).data.map(customer) }),
      create: async params => customer(await client.customers.create(params)),
    },
    paymentIntents: { retrieve: id => client.paymentIntents.retrieve(id) },
    charges: { retrieve: id => client.charges.retrieve(id) },
    checkout: { sessions: { create: params => client.checkout.sessions.create(params), retrieve: id => client.checkout.sessions.retrieve(id) } },
    webhooks: { constructEvent: (body, signature, secret) => client.webhooks.constructEvent(body, signature, secret) },
  };
}
export function getContext(): Context {
  // Fail closed rather than falling through to real payments with fake mode misconfigured.
  if (process.env.STRIPE_FAKE === '1' && process.env.NODE_ENV === 'production') throw new ApiError('not_found');
  const env = environment(process.env), now = () => Math.floor(Date.now() / 1000);
  let stripe: StripePort;
  if (env.STRIPE_FAKE === '1') {
    if (!globalThis.oilFindFakeStripe) {
      const fake = createFakeStripe({ siteURL: env.SITE_URL, now });
      const lifetime = fake.seedCustomer({ email: 'lifetime@example.com', plan: 'lifetime' });
      // The development license key is the explicit exception to redacted logs.
      console.info(`Fake Stripe lifetime key: ${encodeKey(lifetime, env.LICENSE_KEY_SECRET)}`);
      globalThis.oilFindFakeStripe = fake;
    }
    stripe = globalThis.oilFindFakeStripe;
  } else {
    if (!globalThis.oilFindStripe || globalThis.oilFindStripe.secret !== env.STRIPE_SECRET_KEY) {
      globalThis.oilFindStripe = { secret: env.STRIPE_SECRET_KEY, port: stripePort(new Stripe(env.STRIPE_SECRET_KEY)) };
    }
    stripe = globalThis.oilFindStripe.port;
  }
  return { stripe, env, now, mail: createMail(env) };
}
export function getFakeContext(): Context | null {
  return process.env.STRIPE_FAKE === '1' && process.env.NODE_ENV !== 'production' ? getContext() : null;
}

export function getSiteURL(): string {
  return environment(process.env).SITE_URL;
}
