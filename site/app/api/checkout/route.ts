import { getContext } from '@/lib/context';
import { checkout } from '@/lib/checkout';
import { errorResponse, handler, redirect } from '@/lib/http';
export const dynamic = 'force-dynamic';
export const GET = handler('GET', 'checkout', async request => {
  const params = new URL(request.url).searchParams;
  if (params.has('plan') && params.get('plan') !== 'lifetime') return errorResponse('invalid_request');
  return redirect(await checkout(getContext(), params.get('plan'), params.get('lang'), request.headers.get('x-vercel-ip-country')));
});
