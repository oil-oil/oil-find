import type { Language } from './dict';

export const PRIVACY_UPDATED_AT = '2026-10-25';
export const PRIVACY_CONTACT_URL = 'https://github.com/oil-oil/oil-find/issues';

type PrivacyCopy = {
  title: string;
  pageTitle: string;
  description: string;
  updated: string;
  introduction: string;
  sections: { title: string; paragraphs: string[]; items?: string[] }[];
  contact: { title: string; body: string; note: string; action: string };
};

export const privacyCopy = {
  zh: {
    title: '隐私政策',
    pageTitle: '隐私政策 · Oil Find',
    description: 'Oil Find 隐私政策：Mac App Store 版与直售版的本地索引、AI 会话、购买、授权、更新和网站数据处理说明。',
    updated: '更新日期：2026-10-25',
    introduction: '本政策说明 Oil Find 的 Mac App Store 版、直售版和官网如何处理数据。两个应用版本的购买、授权和更新机制不同，请按你使用的版本阅读。',
    sections: [
      {
        title: 'Mac App Store 版',
        paragraphs: [
          '开发者不收集你的用户文件内容、搜索词或本地 AI 对话。Mac App Store 版的数据处理方式如下：',
          '购买和支付由 Apple 处理，Oil Find 不接触完整支付卡信息。试用锚点保存在本机的 defaults 或 Keychain 中。Apple 对 App Store 和购买服务所需数据的处理，适用 Apple 的隐私政策。',
        ],
        items: [
          '索引范围：只索引你明确授权的目录和外置盘，并保存安全作用域书签（security-scoped bookmark）以维持访问权限。未授权的目录不会被扫描或监听。',
          '本地识别与索引：图片和文档的内容识别与索引均在你的 Mac 上完成。',
          'AI 会话：根据你选择的 AI 提供商（provider），只访问该来源所需的最小目录，或你明确导入的内容；不读取提供商凭据，也不上传用户内容。',
          '更新与分析：不包含应用内更新，也不向第三方分析或广告服务上传数据。',
        ],
      },
      {
        title: '直售版',
        paragraphs: ['直售版的图片和文档内容识别与索引也在本机完成。授权、订单和更新流程另有以下数据处理：'],
        items: [
          '许可授权：激活、刷新和停用会处理授权码、设备标识，以及用于区分设备的必要设备名称。',
          '官网订单与找回：下单和找回授权码会处理邮箱及订单信息，Stripe 也会在其支付服务中处理相关信息。完整银行卡信息由 Stripe 处理，不经过我们的服务器。',
          '每日更新：只下载版本清单或安装包，不上传文件内容或搜索词。',
        ],
      },
      {
        title: '官网',
        paragraphs: ['Oil Find 官网使用不带 Cookie 的匿名访问统计，用于了解页面访问情况。官网订单和授权码找回的数据处理见“直售版”。'],
      },
    ],
    contact: {
      title: '联系方式',
      body: '如果你对本政策或 Oil Find 的隐私实践有疑问，请通过 GitHub Issues 联系开发者。',
      note: '请不要在公开 Issue 中发布授权码、支付信息或个人文件。',
      action: '在 GitHub Issues 中提问',
    },
  },
  en: {
    title: 'Privacy Policy',
    pageTitle: 'Privacy Policy · Oil Find',
    description: 'How Oil Find handles local indexing, AI conversations, purchases, licensing, updates, and website data in the Mac App Store and direct-sale versions.',
    updated: 'Last updated: 2026-10-25',
    introduction: 'This policy explains how the Mac App Store version of Oil Find, the direct-sale version, and this website handle data. Purchases, licensing, and updates differ between the two app versions, so please read the section for the version you use.',
    sections: [
      {
        title: 'Mac App Store version',
        paragraphs: [
          'The developer does not collect your user file contents, search terms, or local AI conversations. The Mac App Store version handles data as follows:',
          'Purchases and payments are handled by Apple, and Oil Find does not have access to full payment card details. The trial anchor is stored locally in macOS defaults or the Keychain. Apple’s processing of data needed for App Store and purchase services is governed by Apple’s privacy policy.',
        ],
        items: [
          'Index scope: Oil Find indexes only folders and external drives you explicitly authorize, and saves security-scoped bookmarks to retain access. It does not scan or monitor unauthorized locations.',
          'On-device recognition and indexing: Image and document content recognition and indexing take place on your Mac.',
          'AI conversations: Oil Find accesses only the minimum directory needed for the AI provider you select, or content you explicitly import. It does not read provider credentials or upload your content.',
          'Updates and analytics: This version has no in-app updater and does not upload data to third-party analytics or advertising services.',
        ],
      },
      {
        title: 'Direct-sale version',
        paragraphs: ['Image and document content recognition and indexing also take place on your Mac in the direct-sale version. Its licensing, ordering, and update flows involve the following additional data processing:'],
        items: [
          'Licensing: Activation, refresh, and deactivation process your license key, a device identifier, and the device name needed to distinguish the device.',
          'Website orders and recovery: Checkout and license-key recovery process your email address and order information. Stripe also processes related information to provide payment services. Full card details are handled by Stripe and do not pass through our servers.',
          'Daily updates: Oil Find only downloads a version manifest or installer, and does not upload file contents or search terms.',
        ],
      },
      {
        title: 'Website',
        paragraphs: ['This website uses anonymous, cookie-free analytics to understand page visits. See “Direct-sale version” for website order and license-key recovery data.'],
      },
    ],
    contact: {
      title: 'Contact',
      body: 'If you have questions about this policy or Oil Find’s privacy practices, contact the developer through GitHub Issues.',
      note: 'Do not post license keys, payment details, or personal files in public issues.',
      action: 'Open GitHub Issues',
    },
  },
} satisfies Record<Language, PrivacyCopy>;
