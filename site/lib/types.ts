import type Stripe from 'stripe';

export type Plan = 'lifetime';
export interface Customer {
  id: string;
  email?: string | null;
  metadata?: Record<string, string>;
  deleted?: boolean;
}
export interface LiveCustomer extends Customer { metadata: Record<string, string> }
export interface Session {
  id: string;
  created: number;
  status: string | null;
  payment_status: string;
  customer: string | { id: string } | null;
  payment_intent: string | { id: string } | null;
  metadata: Record<string, string> | null;
  url: string | null;
  success_url: string | null;
}
export interface Charge {
  id: string;
  created: number;
  refunded: boolean;
  customer: string | { id: string } | null;
  payment_intent: string | { id: string } | null;
}
export interface PaymentIntent { id: string; latest_charge: string | Charge | null }
export interface Event { type: string; data: { object: unknown } }
export interface StripePort {
  customers: {
    retrieve(id: string): Promise<Customer>;
    update(id: string, params: { metadata: Record<string, string> }): Promise<Customer>;
    list(params: { email: string; limit: number }): Promise<{ data: Customer[] }>;
    create(params: { email?: string; metadata?: Record<string, string> }): Promise<Customer>;
  };
  paymentIntents: { retrieve(id: string): Promise<PaymentIntent> };
  charges: { retrieve(id: string): Promise<Charge> };
  checkout: { sessions: {
    create(params: Stripe.Checkout.SessionCreateParams): Promise<Session>;
    retrieve(id: string): Promise<Session>;
  } };
  webhooks: { constructEvent(body: string, signature: string, secret: string): Event };
}
export interface Env {
  STRIPE_SECRET_KEY: string;
  STRIPE_WEBHOOK_SECRET: string;
  STRIPE_PRICE_LIFETIME: string;
  LICENSE_SIGNING_KEY: string;
  LICENSE_KEY_SECRET: string;
  SITE_URL: string;
  RESEND_API_KEY: string;
  MAIL_FROM: string;
  MAIL_REPLY_TO: string;
  STRIPE_FAKE: string;
}
export interface Mail {
  configured: boolean;
  send(email: string, key: string, idempotencyKey?: string): Promise<void>;
}
export interface Context { stripe: StripePort; env: Env; now: () => number; mail: Mail }
