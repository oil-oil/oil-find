import { fulfillSession, retrieveSession } from './checkout';
import { ApiError } from './http';
import type { FakeStripe } from './fake-stripe';
import type { Context } from './types';

export async function fakePay(ctx: Context, id: string | null): Promise<string> {
  const open = await retrieveSession(ctx, id);
  const session = await (ctx.stripe as FakeStripe).completeSession(open.id);
  await fulfillSession(ctx, session);
  if (!session.success_url) throw new ApiError('invalid_request');
  return session.success_url.replace('{CHECKOUT_SESSION_ID}', session.id);
}
