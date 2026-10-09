import { createHash, createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';

const args = process.argv.slice(2);
const option = name => { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; };
function bytes(value, length) {
  if (!value || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) throw new Error('Invalid key configuration');
  const result = Buffer.from(value, 'base64');
  if (result.length !== length || result.toString('base64').replace(/=+$/, '') !== value.replace(/=+$/, '')) throw new Error('Invalid key configuration');
  return result;
}
function privateKey() {
  const seed = process.env.LICENSE_SIGNING_KEY || (process.env.STRIPE_FAKE === '1' && process.env.NODE_ENV !== 'production' ? Buffer.alloc(32, 1).toString('base64') : '');
  return createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), bytes(seed, 32)]), format: 'der', type: 'pkcs8' });
}
try {
  const token = option('--verify');
  if (token) {
    const parts = token.split('.');
    if (parts.length !== 2 || parts.some(part => !/^[A-Za-z0-9_-]+$/.test(part))) throw new Error('Invalid token');
    const payload = Buffer.from(parts[0], 'base64url'), signature = Buffer.from(parts[1], 'base64url');
    if (signature.length !== 64 || payload.toString('base64url') !== parts[0] || signature.toString('base64url') !== parts[1]) throw new Error('Invalid token');
    const rawPublic = option('--public-key');
    const key = rawPublic ? createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), bytes(rawPublic, 32)]), format: 'der', type: 'spki' }) : createPublicKey(privateKey());
    if (!verify(null, payload, key, signature)) throw new Error('Invalid signature');
    console.log('Signature verified');
    console.log(payload.toString('utf8'));
  } else {
    const customer = option('--customer'), device = option('--device'), plan = option('--plan');
    const iat = Number(option('--iat') ?? Math.floor(Date.now() / 1000));
    if (!/^cus_[A-Za-z0-9]+$/.test(customer ?? '') || !/^[a-f0-9]{32}$/.test(device ?? '') ||
        plan !== 'lifetime' || !Number.isSafeInteger(iat) || iat < 0) {
      throw new Error('Usage: --customer cus_... --device <32 lowercase hex> --plan lifetime [--email ...] [--iat ...]; --verify <token> [--public-key <base64>]');
    }
    const payload = Buffer.from(JSON.stringify({ v: 1, lic: createHash('sha256').update(customer).digest('hex').slice(0, 16),
      dev: device, plan, email: option('--email') ?? '', iat, exp: 0 }));
    console.log(`${payload.toString('base64url')}.${sign(null, payload, privateKey()).toString('base64url')}`);
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
