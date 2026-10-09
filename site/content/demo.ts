import type { Language } from './dict';
export interface DemoFile { name: string; dir: string; when: string; size: string; kind: string; py: string }
type DemoFileTuple = [string | [string, string], string | [string, string], string, string, string, string];
export interface Query { pos: string[]; neg: string[]; exts: string[]; paths: string[]; today: boolean; empty: boolean }

export const FILES: readonly DemoFileTuple[] = [
  ['README.md', '~/Developer/tidepool', 't11:49', '8 KB', 'doc', ''],
  ['readme-assets', '~/Developer/tidepool/docs', 'y16:12', 'folder', 'folder', ''],
  ['README.md', '~/Developer/tidepool/node_modules/vite', 'd3-14', '5 KB', 'doc', ''],
  ['文档', '~/Desktop', 'd9-27', 'folder', 'folder', 'wendang wd'],
  ['项目文档', '~/Documents', 'd9-14', 'folder', 'folder', 'xiangmuwendang xmwd'],
  ['接口文档.md', '~/Developer/tidepool/docs', 't09:31', '11 KB', 'doc', 'jiekouwendang jkwd'],
  ['产品需求文档-v3.pdf', '~/Downloads', 'd4-17', '2.1 MB', 'doc', 'chanpinxuqiuwendang cpxqwd'],
  ['Xcode.app', '/Applications', 'd6-20', 'app', 'app', ''],
  ['Figma.app', '/Applications', 'd8-2', 'app', 'app', ''],
  [['计算器.app', 'Calculator.app'], '/System/Applications', 'd5-21', 'app', 'app', 'jisuanqi jsq'],
  ['hero@2x.png', '~/Desktop', 't15:51', '812 KB', 'image', ''],
  [['封面-最终版.png', 'cover-final.png'], ['~/Desktop/素材', '~/Desktop/assets'], 'd9-7', '4.3 MB', 'image', 'fengmian fm zuizhongban'],
  ['logo-mark.png', '~/Developer/tidepool/public', 'd9-21', '36 KB', 'image', ''],
  [['截屏 2026-09-30 14.22.08.png', 'Screenshot 2026-09-30 at 14.22.08.png'], '~/Desktop', 'y14:22', '1.8 MB', 'image', 'jieping jp'],
  ['package.json', '~/Developer/tidepool', 'd9-27', '2 KB', 'code', ''],
  ['main.swift', '~/Developer/tidepool-mac/Sources', 't15:54', 'b374', 'code', ''],
  [['周报-09.md', 'weekly-09.md'], ['~/Documents/周报', '~/Documents/weekly'], 't10:05', '3 KB', 'doc', 'zhoubao zb'],
  [['发票-2026-08.pdf', 'invoice-2026-08.pdf'], ['~/Documents/报销', '~/Documents/expenses'], 'd9-2', '148 KB', 'doc', 'fapiao fp'],
  ['changelog.md', '~/Developer/tidepool', 'y18:40', '6 KB', 'doc', ''],
];

export function demoFiles(lang: Language): DemoFile[] {
  return FILES.map(([name, dir, when, size, kind, py]) => {
    const pick = (v: string | [string, string]) => Array.isArray(v) ? v[lang === 'en' ? 1 : 0] : v;
    const localized = Array.isArray(name) && lang === 'en';
    return { name: pick(name), dir: pick(dir), when, size, kind, py: localized ? '' : py };
  });
}

export const KINDS = [null, 'folder', 'app', 'doc', 'image', 'code'] as const;
export const RUN: readonly [string, string][] = [['r', '12'], ['re', '8'], ['rea', '5'], ['read', '3'], ['readm', '2'], ['readme', '2']];

export function parse(raw: string): Query {
  const q: Query = { pos: [], neg: [], exts: [], paths: [], today: false, empty: true };
  for (const token of raw.trim().split(/\s+/).filter(Boolean)) {
    const t = token.toLowerCase();
    q.empty = false;
    if (t === 'dm:today') q.today = true;
    else if (t.startsWith('ext:')) q.exts.push(...t.slice(4).split(';').filter(Boolean));
    else if (t.startsWith('*.') && t.length > 2) q.exts.push(t.slice(2));
    else if (t[0] === '!' && t.length > 1) q.neg.push(t.slice(1));
    else if (t.includes('/')) q.paths.push(t.replace(/\/+$/, ''));
    else q.pos.push(t);
  }
  return q;
}
export function match(file: DemoFile, q: Query, kind: string | null) {
  if (kind && file.kind !== kind) return false;
  const name = file.name.toLowerCase();
  const full = (file.dir + '/' + file.name).toLowerCase();
  const ext = name.includes('.') ? name.slice(name.lastIndexOf('.') + 1) : '';
  if (q.today && file.when[0] !== 't') return false;
  if (q.exts.length && !q.exts.includes(ext)) return false;
  if (q.neg.some(t => full.includes(t))) return false;
  if (!q.paths.every(p => full.startsWith(p + '/') || full.includes('/' + p.replace(/^\//, '') + '/'))) return false;
  return q.pos.every(t => name.includes(t) || file.py.split(' ').some(k => k && k.includes(t)));
}
