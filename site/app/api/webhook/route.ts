import { getContext } from '@/lib/context';
import { webhook } from '@/lib/checkout';
import { handler, json } from '@/lib/http';
export const dynamic = 'force-dynamic';
export const POST = handler('POST', 'webhook', async request =>
  json(await webhook(getContext(), await request.text(), request.headers.get('stripe-signature'))));
