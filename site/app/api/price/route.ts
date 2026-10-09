import { visitorPrice } from '@/lib/price';
import { handler, json } from '@/lib/http';

export const dynamic = 'force-dynamic';
export const GET = handler('GET', 'price', async request =>
  json(visitorPrice(request.headers.get('x-vercel-ip-country'))));
