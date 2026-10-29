import { NextResponse, type NextRequest } from 'next/server';
import { API_METHODS, errorResponse } from './lib/http';
import { chineseRegions, crawlerAgent, LANGUAGE_COOKIE, preferredLanguage } from './lib/language';

const publicPaths = new Set(['/', '/pro', '/changelog', '/syntax', '/everything-for-mac', '/privacy']);

export function proxy(request: NextRequest): Response {
  const path = request.nextUrl.pathname.replace(/\/$/, '') || '/';
  if (path === '/api' || path.startsWith('/api/')) {
    if (path === '/api/fake-pay' &&
        (process.env.STRIPE_FAKE !== '1' || process.env.NODE_ENV === 'production')) return errorResponse('not_found');
    const method = API_METHODS[path.replace(/^\/api\//, '')];
    if (method && request.method !== method) return errorResponse('method_not_allowed');
    const response = NextResponse.next();
    response.headers.set('Cache-Control', 'no-store');
    return response;
  }
  const response = NextResponse.next();
  if (!publicPaths.has(path)) return response;
  const language = preferredLanguage(request.headers.get('accept-language'));
  const region = request.headers.get('x-vercel-ip-country')?.toUpperCase();
  const chosen = request.cookies.get(LANGUAGE_COOKIE)?.value;
  const redirect = !['zh', 'en'].includes(chosen ?? '') && language && !/^zh(?:-|$)/.test(language) &&
    !chineseRegions.has(region ?? '') && !crawlerAgent.test(request.headers.get('user-agent') ?? '');
  if (!redirect) return response;
  const url = request.nextUrl.clone();
  url.pathname = '/en' + (path === '/' ? '' : path);
  const result = NextResponse.redirect(url, 307);
  result.headers.set('Vary', 'Accept-Language, Cookie, X-Vercel-IP-Country');
  // Visitor-specific redirects must not be shared by caches.
  result.headers.set('Cache-Control', 'private, no-store');
  return result;
}
export const config = { matcher: ['/api/:path*', '/', '/pro', '/changelog', '/syntax', '/everything-for-mac', '/privacy'] };
