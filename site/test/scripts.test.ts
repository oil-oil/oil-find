import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { expect, it } from 'vitest';

it('generates local keys privately without reading or overwriting an existing file', () => {
  const directory = mkdtempSync(join(tmpdir(), 'oilfind-keys-'));
  const script = fileURLToPath(new URL('../scripts/gen-keys.mjs', import.meta.url));
  try {
    const generate = () => spawnSync(process.execPath, [script], { cwd: directory, encoding: 'utf8' });
    const first = generate();
    expect(first.status).toBe(0);
    expect(first.stdout).toMatch(/LICENSE_PUBLIC_KEY=[A-Za-z0-9+/]{43}=/);
    expect(first.stdout + first.stderr).not.toMatch(/LICENSE_SIGNING_KEY=|LICENSE_KEY_SECRET=/);
    const file = join(directory, '.env.local'), before = statSync(file);
    expect(before.mode & 0o777).toBe(0o600);
    const second = generate();
    expect(second.status).toBe(1);
    expect(second.stdout + second.stderr).not.toMatch(/LICENSE_SIGNING_KEY=|LICENSE_KEY_SECRET=/);
    const after = statSync(file);
    expect([after.ino, after.size, after.mtimeMs]).toEqual([before.ino, before.size, before.mtimeMs]);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
