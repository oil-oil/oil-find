import { createHmac, timingSafeEqual } from 'node:crypto';
import type Stripe from 'stripe';
import type { Charge, Customer, Event, PaymentIntent, Plan, Session, StripePort } from './types';

export interface SeedCustomer {
  email?: string;
  plan?: Plan;
}
export function createFakeStripe(options: { siteURL?: string; now?: () => number } = {}) {
  const siteURL = options.siteURL ?? 'http://localhost:8787';
  const now = options.now ?? (() => 1790000000);
  const customers = new Map<string, Customer>();
  const sessions = new Map<string, Session>();
  const params = new Map<string, Stripe.Checkout.SessionCreateParams>();
  const payments = new Map<string, PaymentIntent>();
  const charges = new Map<string, Charge>();
  let counter = 0;
  const id = (prefix: string) => `${prefix}_${String(++counter).padStart(14, '0')}`;
  const copy = <T>(value: T): T => structuredClone(value);
  function missing(): never { throw Object.assign(new Error('Fake resource not found'), { statusCode: 404 }); }
  function retrieveCustomer(customerID: string) { const item = customers.get(customerID); return item ? copy(item) : missing(); }
  function signWebhook(body: string, secret: string, timestamp = now()): string {
    return `t=${timestamp},v1=${createHmac('sha256', secret).update(`${timestamp}.${body}`).digest('hex')}`;
  }
  const port: StripePort = {
    customers: {
      async retrieve(customerID) { return retrieveCustomer(customerID); },
      async update(customerID, input) {
        const item = retrieveCustomer(customerID);
        item.metadata = { ...item.metadata };
        for (const [key, value] of Object.entries(input.metadata)) {
          if (value === '') delete item.metadata[key]; else item.metadata[key] = value;
        }
        customers.set(customerID, item);
        return copy(item);
      },
      async list(input) {
        return { data: [...customers.values()].filter(item => !item.deleted && item.email?.trim().toLowerCase() === input.email.trim().toLowerCase()).slice(0, input.limit).map(copy) };
      },
      async create(input) {
        const item: Customer = { id: id('cus'), email: input.email ?? null, metadata: copy(input.metadata ?? {}) };
        customers.set(item.id, item); return copy(item);
      },
    },
    paymentIntents: { async retrieve(paymentID) { const item = payments.get(paymentID); return item ? copy(item) : missing(); } },
    charges: { async retrieve(chargeID) { const item = charges.get(chargeID); return item ? copy(item) : missing(); } },
    checkout: { sessions: {
      async create(input) {
        const sessionID = id('cs_test');
        const item: Session = { id: sessionID, created: now(), status: 'open', payment_status: 'unpaid', customer: null,
          payment_intent: null, metadata: copy(input.metadata as Record<string, string> ?? {}),
          url: `${siteURL}/api/fake-pay?session_id=${sessionID}`, success_url: input.success_url ?? null };
        sessions.set(sessionID, item); params.set(sessionID, copy(input)); return copy(item);
      },
      async retrieve(sessionID) { const item = sessions.get(sessionID); return item ? copy(item) : missing(); },
    } },
    webhooks: { constructEvent(body, signature, secret) {
      const timestamp = Number(/(?:^|,)t=(\d+)/.exec(signature)?.[1]);
      const actual = /(?:^|,)v1=([a-f0-9]{64})(?:,|$)/.exec(signature)?.[1];
      const expected = signWebhook(body, secret, timestamp).split('v1=')[1];
      if (!actual || !Number.isSafeInteger(timestamp) || Math.abs(now() - timestamp) > 300 ||
          !timingSafeEqual(Buffer.from(actual, 'hex'), Buffer.from(expected, 'hex'))) throw new Error('Invalid signature');
      const event = JSON.parse(body) as Event;
      if (typeof event.type !== 'string' || !event.data || !('object' in event.data)) throw new Error('Invalid event');
      return event;
    } },
  };
  return Object.assign(port, {
    seedCustomer(input: SeedCustomer): string {
      const customerID = id('cus');
      customers.set(customerID, { id: customerID, email: input.email ?? null, metadata: input.plan === 'lifetime' ? { lifetime: '1' } : {} });
      return customerID;
    },
    deleteCustomer(customerID: string) { customers.set(customerID, { id: customerID, deleted: true }); },
    setSession(sessionID: string, changes: Partial<Session>) {
      const item = sessions.get(sessionID); if (!item) missing();
      sessions.set(sessionID, { ...item!, ...copy(changes) });
    },
    async completeSession(sessionID: string): Promise<Session> {
      const item = await port.checkout.sessions.retrieve(sessionID);
      if (item.status === 'complete') return item;
      const customer = await port.customers.create({ email: 'buyer@example.com' });
      item.customer = customer.id; item.status = 'complete'; item.payment_status = 'paid';
      item.payment_intent = id('pi');
      const chargeID = id('ch');
      charges.set(chargeID, { id: chargeID, created: now(), refunded: false, customer: customer.id, payment_intent: item.payment_intent });
      payments.set(item.payment_intent, { id: item.payment_intent, latest_charge: chargeID });
      sessions.set(sessionID, copy(item)); return copy(item);
    },
    setCharge(chargeID: string, changes: Partial<Charge>) {
      const item = charges.get(chargeID); if (!item) missing();
      charges.set(chargeID, { ...item!, ...copy(changes) });
    },
    setPaymentIntent(paymentID: string, changes: Partial<PaymentIntent>) {
      const item = payments.get(paymentID); if (!item) missing();
      payments.set(paymentID, { ...item!, ...copy(changes) });
    },
    sessionParams(sessionID: string) { return copy(params.get(sessionID)); },
    signWebhook,
  });
}
export type FakeStripe = ReturnType<typeof createFakeStripe>;
