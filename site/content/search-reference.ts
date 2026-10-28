import { dict, type Language } from './dict';
import copy from './seo-pages.json';

export const syntaxCopy = copy.syntax;
export const everythingCopy = copy.everything;
export const referenceCopy = {
  zh: { syntax: '搜索语法', everything: 'Mac 上的 Everything', allSyntax: '查看全部语法', analytics: '本站使用不带 Cookie 的匿名访问统计。', query: '输入', meaning: '意思', key: '按键', action: '作用', copy: '拷贝', copied: '已拷贝', copyFailed: '未能拷贝，请选中文字拷贝。' },
  en: { syntax: 'Search Syntax', everything: 'Everything for Mac', allSyntax: 'See all syntax', analytics: 'This site uses anonymous, cookie-free analytics.', query: 'Type', meaning: 'Meaning', key: 'Key', action: 'Action', copy: 'Copy', copied: 'Copied', copyFailed: 'Could not copy. Select the text to copy it.' },
};

// Keep the landing examples authoritative and extend them with the README reference.
export function syntaxRows(lang: Language): { queries: string[]; meaning: string }[] {
  const examples = dict[lang].syntax;
  return [
    { queries: [examples[0][0]], meaning: examples[0][1] },
    { queries: ['wendang'], meaning: lang === 'zh' ? '拼音首字母或全拼，能找到「文档」' : 'Pinyin initials or full pinyin, finds 文档' },
    { queries: ['foo bar'], meaning: lang === 'zh' ? '同时包含 foo 和 bar' : 'Contains both foo and bar' },
    { queries: ['foo | bar'], meaning: lang === 'zh' ? '包含 foo 或 bar' : 'Contains foo or bar' },
    ...examples.slice(1, 4).map(([query, meaning]) => ({ queries: [query], meaning })),
    { queries: ['ext:pdf;docx', 'ext:pdf,docx'], meaning: lang === 'zh' ? '按扩展名' : 'By extension' },
    { queries: ['noext:'], meaning: lang === 'zh' ? '查找无扩展名的文件，如 Makefile' : 'Files without an extension, such as Makefile' },
    { queries: ['kind:image'], meaning: lang === 'zh' ? '按类型：folder、app、doc、image、video、audio、code、archive' : 'By kind: folder, app, doc, image, video, audio, code, archive' },
    { queries: ['file:', 'folder:'], meaning: lang === 'zh' ? '只要文件，或只要文件夹' : 'Files only, or folders only' },
    { queries: ['size:>10mb', 'size:1mb..5mb'], meaning: lang === 'zh' ? '按大小' : 'By size' },
    { queries: ['dm:today', 'dm:week', 'dm:2026-10-01'], meaning: lang === 'zh' ? '按修改时间' : 'By modification date' },
    { queries: ['regex:^IMG_\\d+'], meaning: lang === 'zh' ? '正则表达式' : 'Regular expressions' },
    { queries: [examples[4][0]], meaning: examples[4][1] },
  ];
}

export const keyboardRows: Record<Language, [string, string][]> = {
  zh: [
    ['⇧⌘F', '打开搜索，可以在设置里改'], ['Return', '打开'], ['⌘Return', '在访达中显示'],
    ['空格 / ⌘Y', '用 Quick Look 预览（选中结果后按空格）'], ['⌘C / ⌥⌘C', '拷贝路径、拷贝名称'],
    ['⌘⌫', '移到废纸篓'], ['Tab / ⌘1…9', '切换类型'], ['⌘/', '语法速查'],
  ],
  en: [
    ['⇧⌘F', 'Open search (configurable in Settings)'], ['Return', 'Open'], ['⌘Return', 'Show in Finder'],
    ['Space / ⌘Y', 'Quick Look (Space after selecting a result)'], ['⌘C / ⌥⌘C', 'Copy path, copy name'],
    ['⌘⌫', 'Move to Trash'], ['Tab / ⌘1…9', 'Switch kind'], ['⌘/', 'Syntax reference'],
  ],
};
