import Image from 'next/image';
import { commonCopy, dict, proCopy, GITHUB_URL, pagePath, type Language, type SitePage } from '@/content/dict';
import { LanguageLink } from './LanguageLink';

export function TopBar({ lang, page = 'home' }: { lang: Language; page?: SitePage }) {
  const t = dict[lang];
  return <header className="bar">
    <a className="brand" href={pagePath(lang)}><Image src="/assets/icon.png" alt="" width={26} height={26} unoptimized />{commonCopy.brand}</a>
    <a className="nav" href={page === 'home' ? '#pro' : pagePath(lang, 'pro')}>{proCopy[lang].nav}</a>
    {page === 'pro' && <LanguageLink lang={lang} page={page} />}
    {page === 'home' && <>
      <a className="nav hide-s" href="#speed">{t['nav.speed']}</a>
      <a className="nav hide-s" href="#syntax">{t['nav.syntax']}</a>
      <a className="nav" href={GITHUB_URL}>{t['nav.github']}</a>
      <LanguageLink lang={lang} page={page} />
      <a className="btn dark small" href="/downloads/Oil-Find.zip">{t['nav.download']}</a>
    </>}
  </header>;
}
