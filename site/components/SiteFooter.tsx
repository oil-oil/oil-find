import { commonCopy, dict, proCopy, GITHUB_URL, pagePath, type Language } from '@/content/dict';
import { changelogTitle } from '@/content/releases';

export function SiteFooter({ lang }: { lang: Language }) {
  const t = dict[lang];
  return <footer className="col end" id="notes">
    <div className="notes">
      <div><b>{t['note.open.h']}</b><span>{t['note.open']}</span></div>
      <div><b>{t['note.opensource.h']}</b><span>{t['note.opensource']}</span></div>
      <div><b>{t['note.fda.h']}</b><span>{t['note.fda']}</span></div>
      <div><b>{t['note.privacy.h']}</b><span>{t['note.privacy']}</span></div>
    </div>
    <div className="legal"><span>{commonCopy.copyright}</span><span className="sp" /><a href={pagePath(lang, 'changelog')}>{changelogTitle[lang]}</a><a href={pagePath(lang, 'pro')}>{proCopy[lang].footer}</a><a href={pagePath(lang, 'recover')}>{proCopy[lang].recover}</a><a href={GITHUB_URL}>{t['legal.github']}</a><a href="/downloads/Oil-Find.zip">{t['legal.download']}</a></div>
  </footer>;
}
