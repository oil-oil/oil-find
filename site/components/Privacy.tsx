import { PRIVACY_CONTACT_URL, PRIVACY_UPDATED_AT, privacyCopy } from '@/content/privacy';
import type { Language } from '@/content/dict';
import { TopBar } from './TopBar';
import { SiteFooter } from './SiteFooter';
import styles from './SearchReference.module.css';

export function Privacy({ lang }: { lang: Language }) {
  const t = privacyCopy[lang];
  return <><TopBar lang={lang} page="privacy" /><main className={`col ${styles.article}`}>
    <h1>{t.title}</h1><p>{t.introduction}</p>
    <p><time dateTime={PRIVACY_UPDATED_AT}>{t.updated}</time></p>
    {t.sections.map(section => <section key={section.title}><h2>{section.title}</h2>
      {section.paragraphs.map(paragraph => <p key={paragraph}>{paragraph}</p>)}
      {section.items && <ul>{section.items.map(item => <li key={item}>{item}</li>)}</ul>}
    </section>)}
    <section><h2>{t.contact.title}</h2><p>{t.contact.body}</p><p>{t.contact.note}</p>
      <div className={styles.actions}><a className="btn soft" href={PRIVACY_CONTACT_URL}>{t.contact.action}</a></div>
    </section>
  </main><SiteFooter lang={lang} /></>;
}
