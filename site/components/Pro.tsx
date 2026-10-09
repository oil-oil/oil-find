import { proCopy, type Language } from '@/content/dict';
import { TopBar } from './TopBar';
import { SiteFooter } from './SiteFooter';
import { ProSection } from './ProSection';
import styles from './ProSection.module.css';
import { StructuredData } from './StructuredData';

function Answer({ text }: { text: string }) {
  return text.split(/(\[[^\]]+\]\([^)]+\))/g).map((part, index) => {
    const link = part.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
    return link ? <a key={index} href={link[2]}>{link[1]}</a> : part;
  });
}

export function Pro({ lang }: { lang: Language }) {
  const t = proCopy[lang];
  return <><StructuredData lang={lang} page="pro" /><TopBar lang={lang} page="pro" /><main>
    <ProSection lang={lang} standalone />
    <section className={`col sect ${styles.questions}`}>
      <h2>{t.questions}</h2>
      <dl>{t.faq.map(item => <div className={styles.question} key={item.q}>
        <dt>{item.q}</dt><dd><Answer text={item.a} /></dd>
      </div>)}</dl>
    </section>
  </main><SiteFooter lang={lang} /></>;
}
