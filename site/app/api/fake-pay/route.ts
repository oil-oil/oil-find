import { getFakeContext } from '@/lib/context';
import { fakePay } from '@/lib/fake-pay';
import { handler, json, redirect } from '@/lib/http';
export const dynamic = 'force-dynamic';
export const GET = handler('GET', 'fake-pay', async request => {
  const ctx = getFakeContext();
  if (!ctx) return json({ error: 'not_found' }, 404);
  return redirect(await fakePay(ctx, new URL(request.url).searchParams.get('session_id')));
});
