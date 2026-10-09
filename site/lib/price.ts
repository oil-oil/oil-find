export type Currency = 'cny' | 'usd';
export interface Price { currency: Currency; amount: number; display: string }

const prices: Record<Currency, Price> = {
  cny: { currency: 'cny', amount: 4900, display: '¥49' },
  usd: { currency: 'usd', amount: 999, display: '$9.99' },
};

// Amounts use Stripe's minor currency units.
export function visitorPrice(country: string | null): Price {
  return prices[country === 'CN' ? 'cny' : 'usd'];
}

export async function loadPriceDisplay(lang: 'zh' | 'en', signal: AbortSignal): Promise<string> {
  const fallback = visitorPrice(lang === 'zh' ? 'CN' : null).display;
  try {
    const response = await fetch('/api/price', { cache: 'no-store', signal });
    if (response.ok) {
      const price: unknown = await response.json();
      if (price && typeof price === 'object' && 'display' in price &&
          (price.display === prices.cny.display || price.display === prices.usd.display)) return price.display;
    }
  } catch {}
  return fallback;
}
