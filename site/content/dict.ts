import { releases } from './releases';

export type Language = 'zh' | 'en';

export interface HomeItem {
  icon: string;
  name: string;
  path: string;
  meta: string;
  meta2?: string;
  act: { href?: string; scroll?: string; fill?: string };
}

interface LandingCopy {
  title: string;
  description: string;
  placeholder: string;
  sort: string;
  dl: string;
  downloadNote: string;
  toastDemo: string;
  noneTitle: string;
  noneBody: string;
  folder: string;
  app: string;
  'nav.speed': string;
  'nav.syntax': string;
  'nav.github': string;
  'nav.download': string;
  'nav.lang': string;
  'speed.h': string;
  'speed.sub': string;
  'speed.frame': string;
  'stat.scan': string;
  'stat.mem': string;
  'stat.live': string;
  'speed.fine': string;
  'syn.h': string;
  'syn.sub': string;
  'source.h': string;
  'source.sub': string;
  'source.download': string;
  'source.github': string;
  'note.open.h': string;
  'note.open': string;
  'note.opensource.h': string;
  'note.opensource': string;
  'note.fda.h': string;
  'note.fda': string;
  'note.privacy.h': string;
  'note.privacy': string;
  'legal.github': string;
  'legal.download': string;
  lead: string[];
  chips: string[];
  hints: [string, string][];
  syntax: [string, string, string][];
  home: HomeItem[];
  statusHome: (n: number) => string;
  statusDemo: (n: number) => string;
  statusReplay: (hits: string) => string;
  items: (n: string | number) => string;
  today: (time: string) => string;
  yesterday: (time: string) => string;
  date: (month: number, day: number) => string;
  bytes: (n: string) => string;
  scopeTitle: string;
  scopeSubtitle: string;
  scopeTabs: string[];
  scopeAllItems: string[];
  scopeKeyboard: string;
  scopeApps: string[];
  scopeSettings: string[];
  scopeClips: string[];
  scopeSampleTag: string;
  scopeClipboardNote: string;
  scopeCalcLabel: string;
  scopeCalcResult: string;
  scopeWebLabel: string;
  scopeEngineLabel: string;
  scopeSubmit: string;
  scopeUrlLabel: string;
  scopeUrlOpen: string;
  scopeEngines: string[];
  scopeOfflineNote: string;
}

export const GITHUB_URL = 'https://github.com/oil-oil/oil-find';

export const dict: Record<Language, LandingCopy> = {
  zh: {
    title: 'Oil Find：文件、应用、剪贴板，一处搜索',
    description: '按 ⌘Space 打开 macOS 搜索面板。搜索文件与应用，选择性保存剪贴板文本、链接和本地文件路径引用，离线计算和单位换算；网页搜索只在你提交时打开。免费开源。',
    'nav.speed': '功能', 'nav.syntax': '语法', 'nav.github': 'GitHub', 'nav.download': '下载', 'nav.lang': 'EN',
    lead: ['文件、应用、剪贴板，', '一处搜索'],
    placeholder: '在这里试试：wd、png、readme',
    sort: '相关度 ⇅',
    dl: '下载 macOS 版',
    downloadNote: '免费开源。macOS 14 及以上，Apple 芯片',
    'speed.h': '从文件到计算，按需切换',
    'speed.sub': '文件和应用留在搜索面板里；剪贴板记录默认关闭；计算离线完成；网页搜索由你明确提交。',
    'speed.frame': '',
    'stat.scan': '文件名索引', 'stat.mem': '剪贴板', 'stat.live': '计算与网页搜索',
    'speed.fine': '下面的范围演示只使用网页内置的合成样例，不会读取你的文件、剪贴板或搜索历史。',
    'syn.h': '想找得更准，就多写一点',
    'syn.sub': '点一行，把它填进上面的搜索框。',
    'source.h': '开源，免费',
    'source.sub': 'MIT 许可证。代码、问题反馈和新版本都在 GitHub 上。',
    'source.download': '下载 macOS 版',
    'source.github': '在 GitHub 上查看',
    'note.open.h': '第一次打开', 'note.open': '应用还没有经过苹果公证。双击后如果被拦下，去「系统设置 → 隐私与安全性」，在底部点「仍要打开」。只需要一次。',
    'note.opensource.h': '开源', 'note.opensource': '代码在 GitHub 上，MIT 许可证。欢迎提问题和改进。',
    'note.fda.h': '完全磁盘访问', 'note.fda': '可选。不开也能用，只是搜不到邮件和其他应用的数据。',
    'note.privacy.h': '隐私', 'note.privacy': '文件引擎只读取名称、大小和修改时间。剪贴板记录默认关闭，启用后保存文本、链接和本地文件/文件夹路径引用，在本机加密并由钥匙串保护；文件只保存路径，不备份或读取正文。敏感、临时、自动生成标记和来源应用排除继续生效，图片内容和尚未生成的文件承诺不采集。网页搜索只在你选择并提交后打开；版本检查只读取版本信息。',
    'legal.github': 'GitHub', 'legal.download': '下载 macOS 版',
    chips: ['全部', '文件夹', '应用', '文档', '图片', '代码'],
    hints: [['↩', '打开'], ['↑↓', '选择'], ['Tab', '切换筛选']],
    statusHome: n => `从这里开始 · ${n} 项`,
    statusDemo: n => `演示数据 · 共 ${n} 项`,
    statusReplay: hits => `合成演示 · ${hits} 项`,
    toastDemo: '这里是演示 · 装上之后按 ↩ 直接打开文件',
    noneTitle: '没有匹配的结果',
    noneBody: '这里只有十几个演示文件。装上之后，搜的是你自己的 Mac。',
    items: n => `${n} 项`,
    today: t => `今天 ${t}`, yesterday: t => `昨天 ${t}`, date: (m, d) => `${m}月${d}日`,
    folder: '文件夹', app: '应用', bytes: n => `${n} 字节`,
    scopeTitle: '选一个范围试试',
    scopeSubtitle: '此处内容是合成演示。网站不会读取本机文件或剪贴板。',
    scopeTabs: ['全部', '应用', '文件', '设置', '剪贴板', '计算示例', '网页搜索'],
    scopeAllItems: ['README.md · ~/Documents', '日历 · 日程与会议', '剪贴板示例 · 文本与链接', '12 × 8 + 5 · 离线结果 101'],
    scopeKeyboard: '⌘0…⌘4 切换范围 · ⌥⌘1…9 选择文件类型',
    scopeApps: ['日历 · 日程与会议', '计算器 · 最近使用', '代码编辑器 · 项目'],
    scopeSettings: ['键盘快捷键 · 键盘', '隐私与安全性 · 系统设置', '显示器 · 显示'],
    scopeClips: ['会议安排：周四下午 2 点', 'https://example.com/research'],
    scopeSampleTag: '合成示例',
    scopeClipboardNote: '应用中的剪贴板历史默认关闭，升级保留已有开启状态和偏好，并兼容已有文本历史。启用后记录文本、链接和本地文件/文件夹路径引用；一组多文件显示名称和数量，可按名称或路径搜索。选中文件历史项按 ⌘C 恢复文件 URL，回 Finder 按 ⌘V 复制文件；Return 检查权限与焦点后直接粘贴，检查失败仅复制并提示。文件移动或删除后无法恢复；整组路径检查失败会保留当前剪贴板，并提示重新复制。可暂停、清空或排除来源应用。',
    scopeCalcLabel: '输入算式或换算示例', scopeCalcResult: '离线结果',
    scopeWebLabel: '搜索词', scopeEngineLabel: '搜索引擎', scopeSubmit: '提交并打开搜索',
    scopeUrlLabel: '网址会直接打开', scopeUrlOpen: '打开示例网址',
    scopeEngines: ['DuckDuckGo', 'Google', 'Bing'],
    scopeOfflineNote: '计算与单位换算在本地完成。网页搜索不会随键入发送内容。',
    home: [
      { icon: 'download', name: '下载 Oil Find', path: '免费开源。macOS 14 及以上，Apple 芯片', meta: releases[0].version, meta2: '1.5 MB', act: { href: '/downloads/Oil-Find.zip' } },
      { icon: 'timer', name: '一个面板，多种搜索范围', path: '文件、应用、设置、剪贴板、离线计算和网页搜索', meta: '范围', act: { scroll: 'scopes' } },
      { icon: 'pinyin', name: '拼音也能搜', path: '输入 <code>wd</code> 找到「文档」，输入 <code>xmwd</code> 找到「项目文档」', meta: '中文', act: { fill: 'wd' } },
      { icon: 'live', name: '剪贴板由你决定', path: '默认关闭；文本、链接和文件路径引用在本机加密保存，可暂停或清空', meta: '选择启用', act: { scroll: 'scopes' } },
      { icon: 'lock', name: '计算离线完成', path: '输入网址直接打开；网页搜索在你提交后才会打开', meta: '本地优先', act: { scroll: 'scopes' } },
      { icon: 'syntax', name: '查询语法', path: '<code>*.pdf</code>　<code>ext:png</code>　<code>!node_modules</code>　<code>dm:today</code>　<code>~/Desktop/</code>', meta: '进阶', act: { scroll: 'syntax' } },
      { icon: 'file', name: '开源', path: 'MIT 许可证，代码在 GitHub 上', meta: 'GitHub', act: { href: GITHUB_URL } },
    ],
    syntax: [
      ['wd', '拼音首字母，找到「文档」', '拼音'],
      ['readme !node_modules', '包含 readme，排除 node_modules 里的', '排除'],
      ['*.png', '通配符，匹配整个名称', '通配'],
      ['~/Desktop/ png', '只在桌面下面找', '路径'],
      ['dm:today ext:md', '今天改过的 Markdown', '时间'],
    ],
  },
  en: {
    title: 'Oil Find: files, apps and clipboard in one search panel',
    description: 'Press ⌘Space to open a native macOS search panel. Find files and apps, opt in to clipboard history for text, links and local file path references, calculate offline and open web searches only when you submit. Free and open source.',
    'nav.speed': 'Features', 'nav.syntax': 'Syntax', 'nav.github': 'GitHub', 'nav.download': 'Download', 'nav.lang': '中文',
    lead: ['Files, apps and clipboard, ', 'in one search panel'],
    placeholder: 'Try it here: wd, png, readme',
    sort: 'Relevance ⇅',
    dl: 'Download for macOS',
    downloadNote: 'Free and open source. macOS 14 or later, Apple silicon',
    'speed.h': 'Switch from finding to doing',
    'speed.sub': 'Search files and apps in one panel. Clipboard capture is opt-in, calculations work offline, and web searches open only when you submit.',
    'speed.frame': '',
    'stat.scan': 'File-name index', 'stat.mem': 'Clipboard', 'stat.live': 'Calculations and web search',
    'speed.fine': 'The scope demo below uses built-in synthetic examples only. It never reads your files, clipboard or search history.',
    'syn.h': 'Write a little more to find exactly that',
    'syn.sub': 'Click a row to try it in the search field above.',
    'source.h': 'Open source and free',
    'source.sub': 'MIT licensed. Code, issues and releases all live on GitHub.',
    'source.download': 'Download for macOS',
    'source.github': 'View on GitHub',
    'note.open.h': 'Opening it the first time', 'note.open': 'The app isn’t notarized by Apple yet. If macOS blocks it, go to System Settings → Privacy & Security and click “Open Anyway” at the bottom. Once is enough.',
    'note.opensource.h': 'Open source', 'note.opensource': 'The code is on GitHub under the MIT license. Issues and pull requests are welcome.',
    'note.fda.h': 'Full Disk Access', 'note.fda': 'Optional. Without it, Mail and other apps’ data can’t be searched.',
    'note.privacy.h': 'Privacy', 'note.privacy': 'The file engine reads names, sizes and modification dates only. Clipboard history is off by default; when enabled, it saves text, links and path references to local files and folders, encrypted locally and protected with Keychain. File references store paths without backing up files or reading contents. Concealed, transient and autogenerated markers and source app exclusions still apply; image content and ungenerated file promises are not captured. Web search opens only after you choose and submit; update checks fetch version info only.',
    'legal.github': 'GitHub', 'legal.download': 'Download for macOS',
    chips: ['All', 'Folders', 'Apps', 'Documents', 'Images', 'Code'],
    hints: [['↩', 'Open'], ['↑↓', 'Select'], ['Tab', 'Switch filter']],
    statusHome: n => `Start here · ${n} items`,
    statusDemo: n => `Demo data · ${n} ${n === 1 ? 'item' : 'items'}`,
    statusReplay: hits => `Synthetic demo · ${hits} items`,
    toastDemo: 'This is a demo · once installed, ↩ opens the file',
    noneTitle: 'No results',
    noneBody: 'There are only a few demo files here. Once installed, it searches your own Mac.',
    items: n => `${n} items`,
    today: t => `Today ${t}`, yesterday: t => `Yesterday ${t}`,
    date: (m, d) => `${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][m - 1]} ${d}`,
    folder: 'Folder', app: 'App', bytes: n => `${n} bytes`,
    scopeTitle: 'Choose a scope to try',
    scopeSubtitle: 'This is a synthetic demo. The site never reads local files or the clipboard.',
    scopeTabs: ['All', 'Apps', 'Files', 'Settings', 'Clipboard', 'Calculate demo', 'Web search'],
    scopeAllItems: ['README.md · ~/Documents', 'Calendar · Events and meetings', 'Clipboard sample · Text and link', '12 × 8 + 5 · Offline result 101'],
    scopeKeyboard: '⌘0…⌘4 switch scopes · ⌥⌘1…9 choose file type',
    scopeApps: ['Calendar · Events and meetings', 'Calculator · Recent', 'Code editor · Projects'],
    scopeSettings: ['Keyboard Shortcuts · Keyboard', 'Privacy & Security · System Settings', 'Displays · Display'],
    scopeClips: ['Meeting plan: Thursday at 2 pm', 'https://example.com/research'],
    scopeSampleTag: 'Synthetic sample',
    scopeClipboardNote: 'Clipboard history in the app is off by default. Upgrades preserve your enabled state and preferences, and existing text history stays compatible. When enabled, it records text, links and local file/folder path references. A file group shows names and a count; search by name or path. Select a file history entry and press ⌘C to restore file URLs, then ⌘V in Finder to copy the files. Return pastes after permission and focus checks; a failed check only copies and tells you. Moved or deleted files cannot be recovered; if any path in the group is missing, the current clipboard is preserved and you are asked to copy the files again. Pause, clear or exclude source apps any time.',
    scopeCalcLabel: 'Enter an expression or conversion', scopeCalcResult: 'Offline result',
    scopeWebLabel: 'Search query', scopeEngineLabel: 'Search engine', scopeSubmit: 'Submit and open search',
    scopeUrlLabel: 'A URL opens directly', scopeUrlOpen: 'Open example URL',
    scopeEngines: ['DuckDuckGo', 'Google', 'Bing'],
    scopeOfflineNote: 'Calculations and unit conversions run locally. Web search does not send text while you type.',
    home: [
      { icon: 'download', name: 'Download Oil Find', path: 'Free and open source. macOS 14 or later, Apple silicon', meta: releases[0].version, meta2: '1.5 MB', act: { href: '/downloads/Oil-Find.zip' } },
      { icon: 'timer', name: 'One panel, several search scopes', path: 'Files, apps, settings, clipboard, offline calculations and web search', meta: 'Scopes', act: { scroll: 'scopes' } },
      { icon: 'pinyin', name: 'Pinyin search', path: 'Type <code>wd</code> to find 文档, <code>xmwd</code> to find 项目文档', meta: 'Chinese', act: { fill: 'wd' } },
      { icon: 'live', name: 'Clipboard on your terms', path: 'Off by default; text, links and file path references are encrypted locally, with pause and clear controls', meta: 'Opt in', act: { scroll: 'scopes' } },
      { icon: 'lock', name: 'Calculations stay offline', path: 'URLs open directly; web searches open only after you submit', meta: 'Local first', act: { scroll: 'scopes' } },
      { icon: 'syntax', name: 'Query syntax', path: '<code>*.pdf</code>　<code>ext:png</code>　<code>!node_modules</code>　<code>dm:today</code>　<code>~/Desktop/</code>', meta: 'Advanced', act: { scroll: 'syntax' } },
      { icon: 'file', name: 'Open source', path: 'MIT licensed. The code is on GitHub', meta: 'GitHub', act: { href: GITHUB_URL } },
    ],
    syntax: [
      ['wd', 'Pinyin initials, finds 文档', 'Pinyin'],
      ['readme !node_modules', 'Contains readme, not inside node_modules', 'Exclude'],
      ['*.png', 'Wildcard, matches the whole name', 'Wildcard'],
      ['~/Desktop/ png', 'Only under the Desktop', 'Path'],
      ['dm:today ext:md', 'Markdown files changed today', 'Date'],
    ],
  },
};

export type SitePage = 'home' | 'changelog';
export function pagePath(lang: Language, page: SitePage = 'home'): string {
  const prefix = lang === 'en' ? '/en' : '';
  return page === 'home' ? prefix || '/' : prefix + '/changelog';
}

export const commonCopy = {
  brand: 'Oil Find',
  copyright: '© 2026 Oil Find',
  shortcutLabel: 'Command Space',
  searchLabel: 'Search',
  ogDescription: '文件、应用、剪贴板，一处搜索。',
} as const;
