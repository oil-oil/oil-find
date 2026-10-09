import { getContext } from '@/lib/context';
import { recover } from '@/lib/checkout';
import { handler, json, readJSON } from '@/lib/http';
export const dynamic = 'force-dynamic';
export const POST = handler('POST', 'recover', async request => {
  const input = await readJSON(request);
  return json(await recover(getContext(), input));
});
