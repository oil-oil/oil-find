import { createPrivateKey, createPublicKey, randomBytes } from 'node:crypto';
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const file = fileURLToPath(new URL('../.env.production.local', import.meta.url));
const backupDirectory = join(homedir(), 'Documents', 'Oil Find Signing');
const backup = join(backupDirectory, 'license-keys.env');
const created = [];
try {
  if (existsSync(file) || existsSync(backup)) throw new Error();
  mkdirSync(backupDirectory, { recursive: true, mode: 0o700 });
  const seed = randomBytes(32);
  const privateKey = createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]), format: 'der', type: 'pkcs8' });
  const publicKey = createPublicKey(privateKey).export({ format: 'der', type: 'spki' }).subarray(-32);
  const secrets = `LICENSE_SIGNING_KEY=${seed.toString('base64')}\nLICENSE_KEY_SECRET=${randomBytes(32).toString('base64')}\n`;
  for (const [path, contents] of [[backup, secrets], [file, `${secrets}SITE_URL=https://find.oiloil.org\nMAIL_FROM=Oil Find <hello@oiloil.org>\n`]]) {
    const fd = openSync(path, 'wx', 0o600);
    created.push(path);
    try { writeFileSync(fd, contents); fsyncSync(fd); } finally { closeSync(fd); }
  }
  // Only the public key is emitted; pipe it directly into the application config.
  console.log(publicKey.toString('base64'));
} catch {
  for (const path of created) { try { unlinkSync(path); } catch {} }
  console.error('无法独占创建正式密钥文件和备份。请检查文件是否已存在及目录权限；现有文件不会被覆盖。');
  process.exitCode = 1;
}
