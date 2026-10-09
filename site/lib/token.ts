import { createPrivateKey, createPublicKey, createHash, sign } from 'node:crypto';
import { secretBytes } from './keys';
import type { Context, Plan } from './types';

export function signingKey(seed: string) {
  const bytes = secretBytes(seed);
  if (bytes.length !== 32) throw new Error('Invalid signing key configuration');
  return createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), bytes]), format: 'der', type: 'pkcs8' });
}
export function publicKeyBase64(seed: string): string {
  return createPublicKey(signingKey(seed)).export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
}
export function signToken(ctx: Context, input: { customerID: string; device: string; plan: Plan; email: string; lifetimePaidAt?: number }): string {
  const iat = ctx.now();
  const exp = input.lifetimePaidAt !== undefined && iat < input.lifetimePaidAt + 14 * 86400 ? input.lifetimePaidAt + 21 * 86400 : 0;
  const payload = Buffer.from(JSON.stringify({ v: 1,
    lic: createHash('sha256').update(input.customerID).digest('hex').slice(0, 16),
    dev: input.device, plan: input.plan, email: input.email, iat,
    exp,
  }));
  const signature = sign(null, payload, signingKey(ctx.env.LICENSE_SIGNING_KEY));
  return `${payload.toString('base64url')}.${signature.toString('base64url')}`;
}
