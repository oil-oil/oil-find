import { createPublicKey, verify } from 'node:crypto';
import { vi } from 'vitest';
import { createFakeStripe } from '@/lib/fake-stripe';
import { environment } from '@/lib/context';
import { publicKeyBase64 } from '@/lib/token';
import type { Context } from '@/lib/types';

export const DEVICE = '0123456789abcdef0123456789abcdef';
export const PUBLIC_KEY = 'tssUo6fXOeA8aavMlpueD4AOsbckIHOzpm5X4xRTbSM=';
export const DOCUMENT_TOKEN = 'eyJ2IjoxLCJsaWMiOiI5Zjg2ZDA4MTg4NGM3ZDY1IiwiZGV2IjoiMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYiLCJwbGFuIjoibGlmZXRpbWUiLCJlbWFpbCI6ImRldkBleGFtcGxlLmNvbSIsImlhdCI6MTc5MDAwMDAwMCwiZXhwIjowfQ.JMeGVgeke6cyh6MPq6LykxQ3iSCw88Ma1c3CRU1nBNDFy6eQlIttq2edDYV_sWpecrTP-Zf1PeiU5-SKJaZ0Bg';
export function fixture(configured = false) {
  let time = 1790000000;
  const env = environment({ STRIPE_FAKE: '1', SITE_URL: 'http://localhost:8787',
    LICENSE_SIGNING_KEY: Buffer.alloc(32, 1).toString('base64'), LICENSE_KEY_SECRET: Buffer.alloc(32, 2).toString('base64') });
  const now = () => time, stripe = createFakeStripe({ siteURL: env.SITE_URL, now });
  const send = vi.fn(async (_email: string, _key: string, _id?: string) => {});
  const ctx: Context = { stripe, env, now, mail: { configured, send } };
  return { ctx, stripe, send, setTime: (value: number) => { time = value; }, advance: (value: number) => { time += value; } };
}
export function verifiedPayload(token: string, publicKey = publicKeyBase64(Buffer.alloc(32, 1).toString('base64'))) {
  const [body, signature] = token.split('.');
  const key = createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(publicKey, 'base64')]), format: 'der', type: 'spki' });
  if (!verify(null, Buffer.from(body, 'base64url'), key, Buffer.from(signature, 'base64url'))) throw new Error('Signature failed');
  return JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
}
