import Image from 'next/image';
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
    <section className={`col sect ${styles.compare}`} id="compare">
      <h2>{t.compare.title}</h2>
      <table className={styles.compareTable}>
        <caption className={styles.srOnly}>{t.compare.title}</caption>
        <colgroup><col /><col className={styles.planColumn} /><col className={styles.planColumn} /></colgroup>
        <thead><tr><th scope="col">{t.compare.feature}</th><th scope="col"><div className={styles.planIdentity}>
          <Image src="/assets/icon.png" alt="" width={40} height={40} unoptimized />
          <span>{t.compare.free}</span><small>{t.compare.freeSummary}</small>
        </div></th><th scope="col"><div className={styles.planIdentity}>
          <Image src="/assets/pro-icon.png" alt="" width={40} height={40} unoptimized />
          <span>{t.compare.pro}</span><small>{t.compare.proSummary}</small>
        </div></th></tr></thead>
        <tbody>{t.compare.rows.map(([feature, free, pro]) => <tr key={feature}>
          <th scope="row">{feature}</th><td>{free}</td><td>{pro}</td>
        </tr>)}</tbody>
      </table>
      <p className={styles.compareNote}>{t.compare.note}</p>
    </section>
    <section className={`col sect ${styles.questions}`}>
      <h2>{t.questions}</h2>
      <dl>{t.faq.map(item => <div className={styles.question} key={item.q}>
        <dt>{item.q}</dt><dd><Answer text={item.a} /></dd>
      </div>)}</dl>
    </section>
  </main><SiteFooter lang={lang} /></>;
}
