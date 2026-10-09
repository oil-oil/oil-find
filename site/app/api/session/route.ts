import { getContext } from '@/lib/context';
import { session } from '@/lib/checkout';
import { handler, json } from '@/lib/http';
export const dynamic = 'force-dynamic';
export const GET = handler('GET', 'session', async request =>
  json(await session(getContext(), new URL(request.url).searchParams.get('session_id'))));
