import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
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

it('creates both production files privately and preserves existing files', () => {
  const directory = mkdtempSync(join(tmpdir(), 'oilfind-production-'));
  // Redirect file paths, without changing HOME or reading environment files.
  const script = readFileSync(new URL('../scripts/gen-production-keys.mjs', import.meta.url), 'utf8')
    .replace("join(homedir(), 'Documents', 'Oil Find Signing')", "join(process.cwd(), 'backup')")
    .replace("fileURLToPath(new URL('../.env.production.local', import.meta.url))", "join(process.cwd(), '.env.production.local')");
  const generate = () => spawnSync(process.execPath, ['--input-type=module'], { cwd: directory, input: script, encoding: 'utf8' });
  try {
    const first = generate();
    expect(first.status).toBe(0);
    expect(/^[A-Za-z0-9+/]{43}=\n$/.test(first.stdout)).toBe(true);
    const files = [join(directory, '.env.production.local'), join(directory, 'backup/license-keys.env')];
    const before = files.map(file => statSync(file));
    expect(before.map(file => file.mode & 0o777)).toEqual([0o600, 0o600]);
    expect(generate().status).toBe(1);
    expect(files.map(file => { const s = statSync(file); return [s.ino, s.size, s.mtimeMs]; }))
      .toEqual(before.map(s => [s.ino, s.size, s.mtimeMs]));
    rmSync(files[0]);
    expect(generate().status).toBe(1);
    expect(() => statSync(files[0])).toThrow();
    rmSync(files[1]);
    mkdirSync(files[0]);
    expect(generate().status).toBe(1);
    expect(() => statSync(files[1])).toThrow();
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

it('suppresses Vercel output and synchronizes without deploying', () => {
  const directory = mkdtempSync(join(tmpdir(), 'oilfind-push-'));
  try {
    const scripts = join(directory, 'scripts'), bin = join(directory, 'bin');
    mkdirSync(scripts); mkdirSync(bin); mkdirSync(join(directory, '.vercel'));
    writeFileSync(join(directory, '.vercel/project.json'), '{}');
    writeFileSync(join(scripts, 'push-env.sh'), readFileSync(new URL('../scripts/push-env.sh', import.meta.url)));
    writeFileSync(join(directory, '.env.production.local'), 'STRIPE_SECRET_KEY=private-placeholder\nSITE_URL=https://example.com\n');
    writeFileSync(join(bin, 'vercel'), '#!/bin/bash\nprintf "%s\\n" "$*" >> "$OILFIND_TEST_CALLS"\ncat >&2\nexit "${OILFIND_TEST_FAILURE:-0}"\n', { mode: 0o755 });
    const calls = join(directory, 'calls');
    const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, OILFIND_TEST_CALLS: calls };
    const run = (extra = {}) => spawnSync('bash', [join(scripts, 'push-env.sh'), '--no-deploy'], { env: { ...env, ...extra }, encoding: 'utf8' });
    const success = run();
    expect(success.status).toBe(0);
    expect((success.stdout + success.stderr).includes('private-placeholder')).toBe(false);
    const invocations = readFileSync(calls, 'utf8');
    expect(invocations.includes('deploy')).toBe(false);
    expect(invocations.includes('production --force --sensitive')).toBe(true);
    const failure = run({ OILFIND_TEST_FAILURE: '1' });
    expect(failure.status).toBe(1);
    expect((failure.stdout + failure.stderr).includes('private-placeholder')).toBe(false);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});
