import { ApiError } from './http';
import type { LiveCustomer, Plan } from './types';

export interface Entitlement { plan: Plan }
export async function entitlement(customer: LiveCustomer): Promise<Entitlement> {
  if (customer.metadata.lifetime !== '1') throw new ApiError('inactive');
  return { plan: 'lifetime' };
}
