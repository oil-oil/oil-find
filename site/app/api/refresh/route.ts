import { getContext } from '@/lib/context';
import { refresh } from '@/lib/license';
import { handler, json, readJSON } from '@/lib/http';
export const dynamic = 'force-dynamic';
export const POST = handler('POST', 'refresh', async request => {
  const input = await readJSON(request);
  return json(await refresh(getContext(), input));
});
