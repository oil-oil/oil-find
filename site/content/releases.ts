export type Release = {
  version: string;
  date: string;
  notes: { zh: string[]; en: string[] };
};

export const changelogTitle = { zh: '更新日志', en: 'Changelog' };

// The single source for the website and the packaged update manifest.
export const releases: Release[] = [
  {
    version: '1.4.1', date: '2026-10-09',
    notes: {
      zh: ['菜单栏菜单里新增「Oil Find Pro…」，点一下直接打开 Pro 设置。'],
      en: ['The menu bar menu now has “Oil Find Pro…”, which opens the Pro settings.'],
    },
  },
  {
    version: '1.4.0', date: '2026-10-09',
    notes: {
      zh: ['新增 Oil Find Pro：外置磁盘拔掉后也能搜到，还能搜图片里的文字和画面。可以免费试用 7 天，在设置里开始。', '免费版的功能不变，仍然开源。'],
      en: ['New: Oil Find Pro. External drives stay searchable after you unplug them, and you can search the text and objects in your images. Try it free for 7 days from Settings.', 'Everything in the free version stays the same and remains open source.'],
    },
  },
  {
    version: '1.3.0', date: '2026-10-06',
    notes: {
      zh: ['Oil Find 开源了，完全免费，不再需要授权。代码在 GitHub：github.com/oil-oil/oil-find。'],
      en: ['Oil Find is now open source and completely free. No license needed. The code is at github.com/oil-oil/oil-find.'],
    },
  },
  {
    version: '1.2.1', date: '2026-10-05',
    notes: {
      zh: ['设置里新增语言切换，可选择跟随系统、中文或 English，切换后立即生效并记住选择。'],
      en: ['Choose Follow System, 中文 or English in Settings. The interface changes immediately and remembers your choice.'],
    },
  },
  {
    version: '1.2.0', date: '2026-10-04',
    notes: {
      zh: ['应用内检查更新：有新版本时提示，一键下载、校验并重启到新版本。', '点击搜索结果时，选中会直接落在那一行，不再滑过去。', '官网新增更新日志。'],
      en: ['Built-in updates: Oil Find tells you when a new version is out, then downloads, verifies and restarts into it.', 'Clicking a result now selects it instantly instead of sliding there.', 'A changelog is now on the website.'],
    },
  },
  {
    version: '1.1.0', date: '2026-10-03',
    notes: {
      zh: [
        '`foo | bar` 中间带空格也能按“或”搜索；`src/ readme` 这类“路径 + 名称”的组合可以直接用。',
        '`!node_modules` 会同时排除 node_modules 文件夹里的所有文件。',
        '设置里能看到哪些位置没有被索引、原因是什么，还能检查某个文件为什么搜不到。',
        '按 ⌘/ 打开语法速查；正则、类型、大小、日期写错时会提示正确写法。',
      ],
      en: [
        '`foo | bar` now works with spaces, and path-plus-name searches like `src/ readme` just work.',
        '`!node_modules` now also excludes everything inside node_modules folders.',
        "Settings now show what isn't indexed and why, and can check why a file can't be found.",
        'Press ⌘/ for a syntax reference. Mistyped regex, kind, size and date filters now explain the right form.',
      ],
    },
  },
  {
    version: '1.0.0', date: '2026-10-01',
    notes: { zh: ['第一个正式版本。'], en: ['First release.'] },
  },
];
