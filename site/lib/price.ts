export type Currency = 'cny' | 'usd';
export interface Price { currency: Currency; amount: number; display: string }

const prices: Record<Currency, Price> = {
  cny: { currency: 'cny', amount: 9900, display: '¥99' },
  usd: { currency: 'usd', amount: 1999, display: '$19.99' },
};

// Amounts use Stripe's minor currency units.
export function visitorPrice(country: string | null): Price {
  return prices[country === 'CN' ? 'cny' : 'usd'];
}
