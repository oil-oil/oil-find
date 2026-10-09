import { NextResponse, type NextRequest } from 'next/server';
import { API_METHODS, errorResponse } from './lib/http';
export function proxy(request: NextRequest): Response {
  if (request.nextUrl.pathname.replace(/\/$/, '') === '/api/fake-pay' &&
      (process.env.STRIPE_FAKE !== '1' || process.env.NODE_ENV === 'production')) return errorResponse('not_found');
  const method = API_METHODS[request.nextUrl.pathname.replace(/^\/api\//, '').replace(/\/$/, '')];
  if (method && request.method !== method) return errorResponse('method_not_allowed');
  const response = NextResponse.next();
  response.headers.set('Cache-Control', 'no-store');
  return response;
}
export const config = { matcher: '/api/:path*' };
