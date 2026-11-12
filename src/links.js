import { randomInt } from 'node:crypto';

const ALPHABET = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
export const CODE_LENGTH = 7;
export const CODE_PATTERN = /^[0-9A-Za-z]{7}$/;
export const MAX_URL_LENGTH = 2048;

// 62^7 ≈ 3.5 trillion codes. crypto.randomInt is a CSPRNG and is unbiased, so
// codes can't be guessed or walked like sequential IDs (no enumeration).
export function generateCode() {
  let code = '';
  for (let i = 0; i < CODE_LENGTH; i++) {
    code += ALPHABET[randomInt(ALPHABET.length)];
  }
  return code;
}

// Only absolute http(s) URLs. Blocks javascript:, data:, file: etc., which
// would turn our redirect into an XSS or phishing vector.
export function normaliseTargetUrl(input) {
  if (typeof input !== 'string' || input.length > MAX_URL_LENGTH) return null;
  let url;
  try {
    url = new URL(input);
  } catch {
    return null;
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
  return url.href;
}
