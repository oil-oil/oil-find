import { getContext } from '@/lib/context';
import { activate } from '@/lib/license';
import { handler, json, readJSON } from '@/lib/http';
export const dynamic = 'force-dynamic';
export const POST = handler('POST', 'activate', async request => {
  const input = await readJSON(request);
  return json(await activate(getContext(), input));
});
