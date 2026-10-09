import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { dict } from '../content/dict';

describe('native syntax reference', () => {
  it('uses every website example, explanation and group verbatim in both languages', () => {
    const swift = readFileSync(new URL('../../Sources/OilFindApp/SyntaxReference.swift', import.meta.url), 'utf8');
    for (const lang of ['zh', 'en'] as const) {
      const section = swift.split(`static let ${lang} = [`)[1].split('\n    ]')[0];
      const rows = [...section.matchAll(/\["([^"]+)", "([^"]+)", "([^"]+)"\]/g)].map(m => m.slice(1));
      expect(rows).toEqual(dict[lang].syntax);
    }
  });
});
