import { createHash, createHmac } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { describe, expect, it, vi } from 'vitest';
import { decodeKey, encodeKey } from '@/lib/keys';
import { signToken } from '@/lib/token';
import { entitlement } from '@/lib/entitlement';
import { activate, refresh, deactivate, getCustomer } from '@/lib/license';
import { cleanName } from '@/lib/devices';
import { DEVICE, DOCUMENT_TOKEN, PUBLIC_KEY, fixture, verifiedPayload } from './helpers';

describe('S1 license keys', () => {
  const secret = Buffer.alloc(32, 2).toString('base64');
  it.each(['cus_AbCd0123456789', 'cus_AbCd0123456789EfGh012345'])('round trips %s', id => {
    const key = encodeKey(id, secret);
    expect(decodeKey(key, secret)).toBe(id);
    expect(decodeKey(`  ${key.toLowerCase().replaceAll('-', ' -  ')}  `, secret)).toBe(id);
    expect(decodeKey(key.slice(5).replaceAll('0', 'O').replaceAll('1', 'I'), secret)).toBe(id);
    expect(decodeKey(key.slice(5).replaceAll('1', 'L'), secret)).toBe(id);
  });
  it('exercises actual 0 and 1 symbols when accepting O, I and L aliases', () => {
    const id = 'cus_00000000000000', key = encodeKey(id, secret).slice(5);
    expect(key).toContain('0'); expect(key).toContain('1');
    expect(decodeKey(key.replaceAll('0', 'O').replaceAll('1', 'I'), secret)).toBe(id);
    expect(decodeKey(key.replaceAll('1', 'L'), secret)).toBe(id);
  });
  it('rejects every meaningful single-symbol mutation, including padding', () => {
    const key = encodeKey('cus_AbCd0123456789', secret).slice(5).replaceAll('-', '');
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    for (let i = 0; i < key.length; i++) for (const replacement of alphabet) {
      if (replacement !== key[i]) expect(decodeKey(key.slice(0, i) + replacement + key.slice(i + 1), secret)).toBeNull();
    }
    expect(decodeKey(`${key}0`, secret)).toBeNull();
    expect(decodeKey(key, Buffer.alloc(32, 3).toString('base64'))).toBeNull();
  });
  it('rejects short input, U and a correctly MACed nonalphanumeric body', () => {
    expect(decodeKey('OILF-1234', secret)).toBeNull();
    expect(decodeKey(encodeKey('cus_AbCd0123456789', secret).replace(/.$/, 'U'), secret)).toBeNull();
    const customer = 'cus_abcdef!0123456';
    const bytes = Buffer.concat([Buffer.from(customer.slice(4)), createHmac('sha256', Buffer.from(secret, 'base64')).update(`oilfind-key-v1:${customer}`).digest().subarray(0, 6)]);
    const bits = [...bytes].map(byte => byte.toString(2).padStart(8, '0')).join('');
    const padded = bits.padEnd(Math.ceil(bits.length / 5) * 5, '0');
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    const encoded = padded.match(/.{5}/g)!.map(chunk => alphabet[parseInt(chunk, 2)]).join('');
    expect(decodeKey(encoded, secret)).toBeNull();
  });
});

describe('S2 signed tokens', () => {
  it('signs complete lifetime payload', () => {
    const plan = 'lifetime';
    const { ctx } = fixture();
    const token = signToken(ctx, { customerID: 'cus_AbCd0123456789', device: DEVICE, plan, email: 'dev@example.com' });
    expect(verifiedPayload(token)).toEqual({ v: 1, lic: createHash('sha256').update('cus_AbCd0123456789').digest('hex').slice(0, 16),
      dev: DEVICE, plan, email: 'dev@example.com', iat: ctx.now(), exp: 0 });
    expect(token).not.toContain('=');
  });
  it('verifies the protocol fixture using its published public key', () => {
    expect(verifiedPayload(DOCUMENT_TOKEN, PUBLIC_KEY)).toEqual({ v: 1, lic: '9f86d081884c7d65', dev: DEVICE, plan: 'lifetime', email: 'dev@example.com', iat: 1790000000, exp: 0 });
  });
  it('the offline CLI emits the same token as the server and verifies it', () => {
    const { ctx } = fixture();
    const options = { env: { ...process.env, NODE_ENV: 'test' as const, LICENSE_SIGNING_KEY: ctx.env.LICENSE_SIGNING_KEY }, encoding: 'utf8' as const };
    const token = execFileSync(process.execPath, ['scripts/mint-token.mjs', '--customer', 'cus_AbCd0123456789', '--device', DEVICE, '--plan', 'lifetime', '--iat', String(ctx.now()), '--email', 'dev@example.com'], options).trim();
    expect(token).toBe(signToken(ctx, { customerID: 'cus_AbCd0123456789', device: DEVICE, plan: 'lifetime', email: 'dev@example.com' }));
    expect(execFileSync(process.execPath, ['scripts/mint-token.mjs', '--verify', token], options)).toContain('Signature verified');
  });
});

describe('S3 entitlement', () => {
  it('accepts the permanent grant and rejects missing or revoked grants', async () => {
    const { ctx, stripe } = fixture();
    const id = stripe.seedCustomer({ plan: 'lifetime' });
    expect(await entitlement(await getCustomer(ctx, id))).toEqual({ plan: 'lifetime' });
    await stripe.customers.update(id, { metadata: { lifetime: '' } });
    await expect(entitlement(await getCustomer(ctx, id))).rejects.toMatchObject({ code: 'inactive' });
    const inactive = stripe.seedCustomer({});
    await expect(entitlement(await getCustomer(ctx, inactive))).rejects.toMatchObject({ code: 'inactive' });
  });
});

describe('S4 device slots', () => {
  it('activates, deduplicates, replaces the oldest, throttles refresh and reuses a freed slot', async () => {
    const { ctx, stripe, advance } = fixture();
    const id = stripe.seedCustomer({ plan: 'lifetime' }), key = encodeKey(id, ctx.env.LICENSE_KEY_SECRET);
    const input = { key, device: DEVICE, name: 'Test Mac' };
    const update = vi.spyOn(stripe.customers, 'update');
    expect((await activate(ctx, input)).devices).toBe(1);
    expect(update).toHaveBeenLastCalledWith(id, { metadata: { device_1: `${DEVICE}|${ctx.now()}|Test Mac` } });
    expect((await activate(ctx, input)).devices).toBe(1);
    expect(update).toHaveBeenCalledTimes(1);
    const second = '2'.repeat(32), third = '3'.repeat(32), fourth = '4'.repeat(32);
    advance(1); await activate(ctx, { ...input, device: second });
    advance(1); await activate(ctx, { ...input, device: third });
    advance(1); expect((await activate(ctx, { ...input, device: fourth })).devices).toBe(3);
    await expect(refresh(ctx, input)).rejects.toMatchObject({ code: 'device_removed' });
    update.mockClear();
    const refreshed = await refresh(ctx, { key, device: fourth });
    expect(refreshed.devices).toBe(3); expect(update).not.toHaveBeenCalled();
    advance(86400); await refresh(ctx, { key, device: fourth }); expect(update).not.toHaveBeenCalled();
    advance(1); await refresh(ctx, { key, device: fourth }); expect(update).toHaveBeenCalledTimes(1);
    expect(Object.keys(update.mock.calls[0][1].metadata)).toEqual(['device_1']);
    expect(await deactivate(ctx, { key, device: fourth })).toEqual({ ok: true });
    expect((await stripe.customers.retrieve(id)).metadata?.device_1).toBeUndefined();
    update.mockClear(); await deactivate(ctx, { key, device: fourth }); expect(update).not.toHaveBeenCalled();
    expect((await activate(ctx, input)).devices).toBe(3);
  });
  it('refreshing recent contact changes the replacement choice', async () => {
    const { ctx, stripe, advance } = fixture();
    const id = stripe.seedCustomer({ plan: 'lifetime' }), key = encodeKey(id, ctx.env.LICENSE_KEY_SECRET);
    for (const device of ['1', '2', '3']) { await activate(ctx, { key, device: device.repeat(32), name: device }); advance(1); }
    advance(86401); await refresh(ctx, { key, device: '1'.repeat(32) });
    await activate(ctx, { key, device: '4'.repeat(32), name: '4' });
    await expect(refresh(ctx, { key, device: '2'.repeat(32) })).rejects.toMatchObject({ code: 'device_removed' });
    expect((await refresh(ctx, { key, device: '1'.repeat(32) })).devices).toBe(3);
  });
  it('sanitizes names, keeps other metadata, updates an existing name once and serializes parallel activations', async () => {
    const { ctx, stripe } = fixture();
    const id = stripe.seedCustomer({ plan: 'lifetime' }), key = encodeKey(id, ctx.env.LICENSE_KEY_SECRET);
    expect(cleanName('A|\r\n' + '🙂'.repeat(50))).toBe('A' + '🙂'.repeat(39));
    const update = vi.spyOn(stripe.customers, 'update');
    await activate(ctx, { key, device: DEVICE, name: 'A|\r\n' + 'B'.repeat(50) });
    await activate(ctx, { key, device: DEVICE, name: 'Renamed' });
    expect(update).toHaveBeenCalledTimes(2);
    expect(update.mock.calls.every(call => Object.keys(call[1].metadata).length === 1)).toBe(true);
    await Promise.all(['2', '3'].map(device => activate(ctx, { key, device: device.repeat(32), name: device })));
    expect((await refresh(ctx, { key, device: DEVICE })).devices).toBe(3);
    expect((await stripe.customers.retrieve(id)).metadata?.lifetime).toBe('1');
  });
});

describe('S5 license failures and validation order', () => {
  it.each([activate, refresh, deactivate])('%s rejects missing fields, bad devices, keys and deleted customers', async operation => {
    const { ctx, stripe } = fixture();
    const id = stripe.seedCustomer({ plan: 'lifetime' }), key = encodeKey(id, ctx.env.LICENSE_KEY_SECRET);
    const input = { key, device: DEVICE, name: 'Mac' };
    const retrieve = vi.spyOn(stripe.customers, 'retrieve');
    for (const value of [{}, { ...input, device: 'ABCDEF'.repeat(6) }, { ...input, device: '1'.repeat(31) }, { ...input, key: 42 }]) {
      await expect(operation(ctx, value)).rejects.toMatchObject({ code: 'invalid_request' });
    }
    await expect(operation(ctx, { ...input, key: 'bad-key' })).rejects.toMatchObject({ code: 'invalid_key' });
    expect(retrieve).not.toHaveBeenCalled();
    await expect(operation(ctx, { ...input, key: encodeKey('cus_notfound123456', ctx.env.LICENSE_KEY_SECRET) })).rejects.toMatchObject({ code: 'invalid_key' });
    stripe.deleteCustomer(id);
    await expect(operation(ctx, input)).rejects.toMatchObject({ code: 'invalid_key' });
  });
  it('activation requires a name, inactive entitlement wins over absent devices; deactivate skips entitlement', async () => {
    const { ctx, stripe } = fixture();
    const id = stripe.seedCustomer({}), key = encodeKey(id, ctx.env.LICENSE_KEY_SECRET);
    await expect(activate(ctx, { key, device: DEVICE })).rejects.toMatchObject({ code: 'invalid_request' });
    await expect(activate(ctx, { key, device: DEVICE, name: 'Mac' })).rejects.toMatchObject({ code: 'inactive' });
    await expect(refresh(ctx, { key, device: DEVICE })).rejects.toMatchObject({ code: 'inactive' });
    expect(await deactivate(ctx, { key, device: DEVICE })).toEqual({ ok: true });
  });
  it('uses an empty string when customer email is absent', async () => {
    const { ctx, stripe } = fixture(), id = stripe.seedCustomer({ plan: 'lifetime' });
    const result = await activate(ctx, { key: encodeKey(id, ctx.env.LICENSE_KEY_SECRET), device: DEVICE, name: '' });
    expect(result.email).toBe(''); expect(verifiedPayload(result.token).email).toBe('');
  });
});
