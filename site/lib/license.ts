import { decodeKey, encodeKey } from './keys';
import { signToken } from './token';
import { entitlement, type Entitlement } from './entitlement';
import { DEVICE_SLOTS, cleanName, deviceValue, readDevices, withCustomerLock, writeMetadata } from './devices';
import { ApiError } from './http';
import type { Context, LiveCustomer } from './types';

export async function getCustomer(ctx: Context, id: string): Promise<LiveCustomer> {
  try {
    const customer = await ctx.stripe.customers.retrieve(id);
    if (customer.deleted) throw new ApiError('invalid_key');
    return { ...customer, metadata: { ...customer.metadata } };
  } catch (error) {
    if ((error as { statusCode?: number })?.statusCode === 404) throw new ApiError('invalid_key');
    throw error;
  }
}
function customerID(ctx: Context, input: Record<string, unknown>, deviceRequired: boolean, nameRequired = false): string {
  if (typeof input.key !== 'string' || !input.key.trim() ||
      (deviceRequired && (typeof input.device !== 'string' || !/^[0-9a-f]{32}$/.test(input.device))) ||
      (nameRequired && typeof input.name !== 'string')) throw new ApiError('invalid_request');
  const id = decodeKey(input.key, ctx.env.LICENSE_KEY_SECRET);
  if (!id) throw new ApiError('invalid_key');
  return id;
}
function license(ctx: Context, customer: LiveCustomer, access: Entitlement, device: string) {
  const email = customer.email ?? '';
  const paidAt = Number(customer.metadata.lifetime_paid_at);
  const lifetimePaidAt = Number.isSafeInteger(paidAt) && paidAt > 0 ? paidAt : undefined;
  return { key: encodeKey(customer.id, ctx.env.LICENSE_KEY_SECRET),
    token: signToken(ctx, { customerID: customer.id, device, plan: access.plan, email, lifetimePaidAt }),
    ...access, email, devices: readDevices(customer.metadata).filter(Boolean).length };
}
export async function activate(ctx: Context, input: Record<string, unknown>) {
  const id = customerID(ctx, input, true, true);
  return withCustomerLock(ctx, id, async () => {
    const customer = await getCustomer(ctx, id);
    const access = await entitlement(customer);
    const devices = readDevices(customer.metadata);
    let slot = devices.findIndex(item => item?.id === input.device);
    if (slot < 0) slot = devices.findIndex(item => !item);
    if (slot < 0) slot = devices.reduce((oldest, item, i) => item!.seen < devices[oldest]!.seen ? i : oldest, 0);
    await writeMetadata(ctx, id, customer.metadata, { [DEVICE_SLOTS[slot]]: deviceValue({
      id: input.device as string, seen: ctx.now(), name: cleanName(input.name as string),
    }) });
    return license(ctx, customer, access, input.device as string);
  });
}
export async function refresh(ctx: Context, input: Record<string, unknown>) {
  const id = customerID(ctx, input, true);
  return withCustomerLock(ctx, id, async () => {
    const customer = await getCustomer(ctx, id);
    const access = await entitlement(customer);
    const devices = readDevices(customer.metadata), slot = devices.findIndex(item => item?.id === input.device);
    if (slot < 0) throw new ApiError('device_removed');
    const device = devices[slot]!;
    if (device.seen < ctx.now() - 86400) {
      await writeMetadata(ctx, id, customer.metadata, { [DEVICE_SLOTS[slot]]: deviceValue({ ...device, seen: ctx.now() }) });
    }
    return license(ctx, customer, access, input.device as string);
  });
}
export async function deactivate(ctx: Context, input: Record<string, unknown>) {
  const id = customerID(ctx, input, true);
  return withCustomerLock(ctx, id, async () => {
    const customer = await getCustomer(ctx, id);
    const slot = readDevices(customer.metadata).findIndex(item => item?.id === input.device);
    if (slot >= 0) await writeMetadata(ctx, id, customer.metadata, { [DEVICE_SLOTS[slot]]: '' });
    return { ok: true };
  });
}
