import { getContext } from '@/lib/context';
import { deactivate } from '@/lib/license';
import { handler, json, readJSON } from '@/lib/http';
export const dynamic = 'force-dynamic';
export const POST = handler('POST', 'deactivate', async request => {
  const input = await readJSON(request);
  return json(await deactivate(getContext(), input));
});
