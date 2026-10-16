import type { Language } from './dict';

export const aiTopicsCopy = {
  "zh": {
    "label": "免费版已包含",
    "title": "忘了在哪个 AI 里聊过？",
    "intro": "按 ⇧⌘F，输入记得的关键词，就能同时找文件和过去的 AI 对话。也可以切换到「AI 话题」，只看对话结果。",
    "sources": "搜索 Claude Code、Codex 和 WorkBuddy 保存在本机的对话标题与正文，也包含 Claude 桌面端的 Code 会话。",
    "settings": "在设置中可以分别开启或关闭每个来源。启用后，Oil Find 会为保存在本机的内容建立索引；已归档的对话不会出现在搜索结果中。",
    "privacy": "对话索引只保存在本机，不会上传。搜索仅涵盖保存在这台 Mac 上的内容，不包括 Claude 普通网页聊天或 WorkBuddy 尚未保存到本机的云端对话。",
    "hero": "文件和保存在本机的 Claude Code、Codex、WorkBuddy 对话，一个快捷键一起搜。"
  },
  "en": {
    "label": "Included in the free version",
    "title": "Which AI did you discuss that with?",
    "intro": "Press ⇧⌘F and type any keyword you remember to find files and past AI conversations together. Switch to AI Topics to see only conversations.",
    "sources": "Search titles and body text saved locally by Claude Code, Codex, and WorkBuddy, including Code sessions in the Claude desktop app.",
    "settings": "Turn each source on or off in Settings. When enabled, Oil Find indexes conversations saved on this Mac. Archived conversations stay out of search results.",
    "privacy": "Conversation indexes stay on your Mac and are never uploaded. Search covers content saved on this Mac, excluding regular Claude web chats and WorkBuddy conversations not saved locally.",
    "hero": "One shortcut searches Mac files and local conversations from Claude Code, Codex, and WorkBuddy."
  }
} satisfies Record<Language, {
  hero: string; label: string; title: string; intro: string;
  sources: string; settings: string; privacy: string;
}>;
