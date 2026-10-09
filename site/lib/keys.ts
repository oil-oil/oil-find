import { createHmac, timingSafeEqual } from 'node:crypto';

const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
export function secretBytes(value: string): Buffer {
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value)) throw new Error('Invalid key configuration');
  const bytes = Buffer.from(value, 'base64');
  if (!bytes.length || bytes.toString('base64').replace(/=+$/, '') !== value.replace(/=+$/, '')) throw new Error('Invalid key configuration');
  return bytes;
}
function mac(customerID: string, secret: string): Buffer {
  return createHmac('sha256', secretBytes(secret)).update(`oilfind-key-v1:${customerID}`).digest().subarray(0, 6);
}
export function encodeKey(customerID: string, secret: string): string {
  if (!/^cus_[A-Za-z0-9]+$/.test(customerID)) throw new Error('Invalid customer ID');
  const bytes = Buffer.concat([Buffer.from(customerID.slice(4), 'ascii'), mac(customerID, secret)]);
  let bits = 0, buffer = 0, output = '';
  for (const byte of bytes) {
    buffer = (buffer << 8) | byte; bits += 8;
    while (bits >= 5) { bits -= 5; output += ALPHABET[(buffer >>> bits) & 31]; }
    buffer &= (1 << bits) - 1;
  }
  if (bits) output += ALPHABET[(buffer << (5 - bits)) & 31];
  return `OILF-${output.match(/.{1,4}/g)!.join('-')}`;
}
export function decodeKey(key: string, secret: string): string | null {
  let normalized = key.toUpperCase().replace(/[^A-Z0-9]/g, '');
  if (normalized.startsWith('OILF')) normalized = normalized.slice(4);
  normalized = normalized.replace(/O/g, '0').replace(/[IL]/g, '1');
  if (normalized.length < 12 || normalized.includes('U')) return null;
  const bytes: number[] = [];
  let bits = 0, buffer = 0;
  for (const character of normalized) {
    const value = ALPHABET.indexOf(character);
    if (value < 0) return null;
    buffer = (buffer << 5) | value; bits += 5;
    if (bits >= 8) { bits -= 8; bytes.push((buffer >>> bits) & 255); }
    buffer &= (1 << bits) - 1;
  }
  // Reject altered padding bits and redundant trailing symbols.
  if (buffer !== 0 || Math.ceil(bytes.length * 8 / 5) !== normalized.length || bytes.length <= 6) return null;
  const decoded = Buffer.from(bytes), body = decoded.subarray(0, -6);
  if (!body.every(byte => (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122))) return null;
  const customerID = `cus_${body.toString('ascii')}`;
  return timingSafeEqual(decoded.subarray(-6), mac(customerID, secret)) ? customerID : null;
}
