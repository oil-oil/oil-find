import { createPrivateKey, createPublicKey, randomBytes } from 'node:crypto';
import { writeFileSync } from 'node:fs';

const seed = randomBytes(32);
const privateKey = createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]), format: 'der', type: 'pkcs8' });
const publicKey = createPublicKey(privateKey).export({ format: 'der', type: 'spki' }).subarray(-32);
// Exclusive creation avoids reading or overwriting an existing local environment.
try {
  writeFileSync('.env.local', `LICENSE_SIGNING_KEY=${seed.toString('base64')}\nLICENSE_KEY_SECRET=${randomBytes(32).toString('base64')}\nLICENSE_PUBLIC_KEY=${publicKey.toString('base64')}\n`, { flag: 'wx', mode: 0o600 });
} catch {
  console.error('Could not create .env.local. Existing files are never overwritten.');
  process.exit(1);
}
console.log('Development keys written to .env.local (permissions 600).');
console.log(`LICENSE_PUBLIC_KEY=${publicKey.toString('base64')}`);
