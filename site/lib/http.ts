export type ErrorCode = 'invalid_request' | 'invalid_key' | 'inactive' | 'device_removed' | 'method_not_allowed' | 'email_not_configured' | 'server_error' | 'not_found';
const status: Record<ErrorCode, number> = { invalid_request: 400, invalid_key: 403, inactive: 402, device_removed: 410, method_not_allowed: 405, email_not_configured: 501, server_error: 500, not_found: 404 };
export class ApiError extends Error {
  constructor(public code: ErrorCode) { super(code); }
}
export function json(value: unknown, code = 200): Response {
  return new Response(JSON.stringify(value), { status: code, headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' } });
}
export function errorResponse(code: ErrorCode): Response { return json({ error: code }, status[code]); }
export function redirect(url: string): Response {
  return new Response(null, { status: 303, headers: { Location: url, 'Cache-Control': 'no-store' } });
}
export async function readJSON(request: Request): Promise<Record<string, unknown>> {
  try {
    const value: unknown = await request.json();
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
    return value as Record<string, unknown>;
  } catch { throw new ApiError('invalid_request'); }
}
export function logError(event: string, code: ErrorCode, customerID?: string): void {
  console.error(JSON.stringify({ event, ...(customerID ? { customer: customerID.slice(-6) } : {}), error: code }));
}
export function handler(method: string, event: string, operation: (request: Request) => Promise<Response>) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== method) return errorResponse('method_not_allowed');
    try { return await operation(request); }
    catch (error) {
      const code = error instanceof ApiError ? error.code : 'server_error';
      if (code === 'server_error') logError(event, code);
      return errorResponse(code);
    }
  };
}
export const API_METHODS: Record<string, string> = {
  activate: 'POST', refresh: 'POST', deactivate: 'POST', checkout: 'GET', session: 'GET',
  price: 'GET', recover: 'POST', webhook: 'POST', 'fake-pay': 'GET',
};
