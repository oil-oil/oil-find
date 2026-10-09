import { commonCopy, dict, footerQuestions, proCopy, GITHUB_URL, pagePath, type Language } from '@/content/dict';
import { changelogTitle } from '@/content/releases';

export function SiteFooter({ lang }: { lang: Language }) {
  const t = dict[lang];
  return <footer className="col end" id="notes">
    <div className="notes">
      {footerQuestions(lang).map(item => <div key={item.q}><b>{item.q}</b><span>{item.a}</span></div>)}
    </div>
    <div className="legal"><span>{commonCopy.copyright}</span><span className="sp" /><a href={pagePath(lang, 'changelog')}>{changelogTitle[lang]}</a><a href={pagePath(lang, 'pro')}>{proCopy[lang].footer}</a><a href={pagePath(lang, 'recover')}>{proCopy[lang].recover}</a><a href={GITHUB_URL}>{t['legal.github']}</a><a href="/downloads/Oil-Find.zip">{t['legal.download']}</a></div>
  </footer>;
}
