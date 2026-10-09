import { describe, expect, it } from 'vitest';
import { demoFiles, match, parse } from '@/content/demo';
import { dict, GITHUB_URL, type Language } from '@/content/dict';
import manifest from '@/public/updates/latest.json';

function names(lang: Language, query: string) {
  const parsed = parse(query);
  return demoFiles(lang).filter(file => match(file, parsed, null)).map(file => file.name);
}

describe.each(['zh', 'en'] as const)('search demonstration (%s)', lang => {
  it('keeps the example searches useful with localized file names', () => {
    expect(names(lang, 'readme !node_modules')).toEqual(['README.md', 'readme-assets']);
    expect(names(lang, 'ext:png')).toHaveLength(4);
    expect(names(lang, '~/Desktop/ png')).toHaveLength(3);
  });

  it('provides the open source action in the demo list', () => {
    expect(dict[lang].home[0].meta).toBe(manifest.version);
    const item = dict[lang].home.at(-1);
    expect(item?.act.href).toBe(GITHUB_URL);
    expect(item?.meta).toBe('GitHub');
  });
});
