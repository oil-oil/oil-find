export type Release = {
  version: string;
  date: string;
  notes: { zh: string[]; en: string[] };
};

export const changelogTitle = { zh: '更新日志', en: 'Changelog' };

// The single source for the website and the packaged update manifest.
export const releases: Release[] = [
  {
    "version": "1.7.1",
    "date": "2026-10-17",
    "notes": {
      "zh": [
        "修复了 1.7.0 在部分电脑上启动直接退出、自动更新失败的问题。AI 话题图标现在会从安装包内正确读取；即使缺少图标，也不会导致应用崩溃。"
      ],
      "en": [
        "Fixed an issue in 1.7.0 where Oil Find would quit unexpectedly on launch and cause automatic updates to fail on some Macs. AI conversation icons now load correctly from within the app bundle, and missing icons will no longer crash the app."
      ]
    }
  },
  {
    "version": "1.7.0",
    "date": "2026-10-16",
    "notes": {
      "zh": [
        "新增免费的本地 AI 话题搜索，支持 Claude Code（含桌面 Code 会话）、Codex 和 WorkBuddy。在一个搜索面板里就能查找会话标题和正文，并直接打开原会话。",
        "可以在设置中分别开启或关闭各个 Agent；未安装的来源默认关闭。归档的话题不会出现在搜索结果中。",
        "减少对 Codex 未变动会话的重复读取，让各个来源轮流同步，并根据新增消息增量更新正文索引。",
        "修复了文件事件丢失后反复全盘重扫，以及保存话题索引时报错提示数据库被锁定的问题。",
        "分类栏新增「AI 话题」分类，并保留了切换动画；设置入口移到底栏右侧，并补充了文字标签。"
      ],
      "en": [
        "Local AI conversation search is now free, with support for Claude Code (including desktop Code sessions), Codex, and WorkBuddy. Search conversation titles and messages from a single panel, and open the original conversation directly.",
        "Enable or disable each Agent in Settings. Uninstalled sources are turned off by default, and archived conversations are excluded from search results.",
        "Reduced repeated reads of unchanged Codex conversations, let sources take turns syncing, and updated the body index incrementally as new messages arrive.",
        "Fixed repeated full disk rescans after lost filesystem events, as well as database lock errors when saving the conversation index.",
        "Added AI Topics to the category bar while keeping the transition animation. The Settings entry has moved to the right side of the bottom bar with an added text label."
      ]
    }
  },
  {
    version: '1.6.2', date: '2026-10-13',
    notes: {
      zh: ['修复文件频繁变化时后台维护任务可能积压的问题：合并尚未完成的维护任务，让图片和文档识别能继续向前处理。', '慢速目录核对结束后再计算下一次维护的间隔，避免连续重复遍历。保留 1.6.1 的 CPU 调度优化。'],
      en: ['Fixed background maintenance tasks accumulating during frequent file changes. Outstanding maintenance tasks are coalesced so image and document recognition can continue making progress.', 'The next maintenance interval now starts when a slow catalog check finishes, avoiding back-to-back repeated scans. Includes the CPU scheduling improvements from 1.6.1.'],
    },
  },
  {
    version: '1.6.1', date: '2026-10-13',
    notes: {
      zh: [
        '降低后台索引和内容识别的持续 CPU 占用：图片和文档分段处理，打字或重建文件目录时自动暂停内容识别。',
        '修复文件变化时已识别的内容搜索结果暂时消失的问题，减少重复遍历和识别中断。',
        '完整文件扫描减少并行线程，为日常搜索和其他应用留出更多资源。首次批量识别会更慢，已完成的内容仍可直接搜索。',
      ],
      en: [
        'Reduced sustained CPU use during background indexing and content recognition. Images and documents are processed with breaks, and content recognition pauses while you type or rebuild the file index.',
        'Fixed recognized content results temporarily disappearing after file changes, with fewer repeated scans and interrupted recognition tasks.',
        'Full file scans use fewer parallel threads to leave more resources for searches and other apps. Initial bulk recognition takes longer; content already recognized remains searchable.',
      ],
    },
  },
  {
    version: '1.6.0', date: '2026-10-12',
    notes: {
      zh: ['外置磁盘搜索现在免费：插上就建立索引并实时更新，在设置的「外置磁盘」里可以逐个关闭。', 'Pro 保留「拔掉后也能搜到」，并继续提供图片和文档内容搜索。', 'Pro 激活后，应用图标会换成戴飞行员墨镜的版本。'],
      en: ['Searching external drives is now free: drives are indexed when you plug them in and kept up to date, and you can turn off any drive in Settings.', 'Pro keeps drives searchable after you unplug them, along with image and document content search.', 'When Pro is active, the app icon switches to a version wearing aviators.'],
    },
  },
  {
    // Packaging confirms the release date before publishing.
    version: '1.5.0', date: '2026-10-11',
    notes: {
      zh: ['Oil Find Pro 新增文档内容搜索：PDF、Word、PowerPoint、Excel、Pages、Markdown 和纯文本里的文字都能搜到，扫描版 PDF 会识别前 10 页。全部在本机处理。'],
      en: ['Oil Find Pro now searches inside documents: PDF, Word, PowerPoint, Excel, Pages, Markdown and plain text, plus the first 10 pages of scanned PDFs. Everything is processed on your Mac.'],
    },
  },
  {
    // Packaging confirms the release date before publishing.
    version: '1.4.2', date: '2026-10-11',
    notes: {
      zh: [
        '用方向键或鼠标选中结果后，按空格就能预览，再按一次关闭；打字时空格照常输入。',
        '设置里新增「排除的文件类型」，可以让 log、js、css 这类文件不出现在结果里。',
        '修复滚动结果列表时会跳回选中项的问题。',
      ],
      en: [
        'Press Space to preview a result after selecting it with the arrow keys or the mouse, and again to close. While typing, Space still types a space.',
        'New in Settings: Excluded File Types keeps files such as log, js and css out of your results.',
        'Fixed the results list jumping back to the selection while scrolling.',
      ],
    },
  },
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
