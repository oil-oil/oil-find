import type { Context, StripePort } from './types';

export const DEVICE_SLOTS = ['device_1', 'device_2', 'device_3'] as const;
export interface Device { id: string; seen: number; name: string }
export function readDevices(metadata: Record<string, string>): (Device | null)[] {
  return DEVICE_SLOTS.map(slot => {
    const match = /^([0-9a-f]{32})\|(\d+)\|([^|\r\n]*)$/.exec(metadata[slot] ?? '');
    if (!match || !Number.isSafeInteger(Number(match[2]))) return null;
    return { id: match[1], seen: Number(match[2]), name: match[3] };
  });
}
export function cleanName(name: string): string { return Array.from(name.replace(/[|\r\n]/g, '')).slice(0, 40).join(''); }
export function deviceValue(device: Device): string { return `${device.id}|${device.seen}|${device.name}`; }
export async function writeMetadata(ctx: Context, customerID: string, metadata: Record<string, string>, desired: Record<string, string>): Promise<void> {
  const changes = Object.fromEntries(Object.entries(desired).filter(([key, value]) => (metadata[key] ?? '') !== value));
  if (Object.keys(changes).length) {
    await ctx.stripe.customers.update(customerID, { metadata: changes });
    Object.assign(metadata, changes);
  }
}

// Serialize read-modify-write operations for each customer within a server process.
const queues = new WeakMap<StripePort, Map<string, Promise<void>>>();
export async function withCustomerLock<T>(ctx: Context, id: string, operation: () => Promise<T>): Promise<T> {
  let queue = queues.get(ctx.stripe);
  if (!queue) { queue = new Map(); queues.set(ctx.stripe, queue); }
  const previous = queue.get(id) ?? Promise.resolve();
  let release!: () => void;
  const current = new Promise<void>(resolve => { release = resolve; });
  queue.set(id, current);
  await previous;
  try { return await operation(); }
  finally { release(); if (queue.get(id) === current) queue.delete(id); }
}
