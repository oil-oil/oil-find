import Image from 'next/image';
import { pagePath, proCopy, type Language } from '@/content/dict';
import { Icon } from './Icon';
import { PriceAmount } from './PriceAmount';
import panel from './SearchPanel.module.css';
import styles from './ProSection.module.css';

function Highlight({ text }: { text: string }) {
  return text.split(/(\*\*[^*]+\*\*)/g).map((part, index) => part.startsWith('**')
    ? <mark key={index}>{part.slice(2, -2)}</mark> : part);
}

export function ProSection({ lang, standalone = false }: { lang: Language; standalone?: boolean }) {
  const t = proCopy[lang];
  const Heading = standalone ? 'h1' : 'h2';
  return <section className={`col sect ${styles.section} ${standalone ? styles.standalone : styles.promotion}`} id="pro">
    <div className={styles.intro}>
      <div className={styles.identity}>
        <Image src="/assets/pro-icon.png" width={64} height={64} alt="" unoptimized />
        <p>{t.title}</p>
      </div>
      <Heading className={styles.heading}>{t.headline}</Heading>
      <p className={styles.subtitle}>{t.subtitle}</p>
      {!standalone && <ul className={styles.capabilities}>
        {t.features.map(feature => <li key={feature.title}>{feature.title}</li>)}
      </ul>}
      <p className={styles.price}><PriceAmount lang={lang} /><span>{t.priceUnit}</span></p>
      <div className={styles.actions}>
        <a className="btn dark big" href={standalone ? `/api/checkout?plan=lifetime&lang=${lang}` : pagePath(lang, 'pro')}>
          {standalone ? t.buy : <>{t.learn} <span aria-hidden="true">→</span></>}
        </a>
        <a className="btn soft big" href="/downloads/Oil-Find.zip">{t.download}</a>
      </div>
      {standalone && <ul className={styles.terms}>{t.terms.map(term => <li key={term}>{term}</li>)}</ul>}
      <div className={styles.trial}>
        <p>{t.trialNote}</p>
        {standalone && <p>{t.trialReassurance}</p>}
        {standalone && <a href="#compare">{t.compareLink} <span aria-hidden="true">↓</span></a>}
      </div>
    </div>
    <div className={styles.demo}>
      <div className={`${panel.panel} ${styles.panel}`} aria-hidden="true">
        <div className={panel.search}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"><circle cx="10.5" cy="10.5" r="6.5" /><path d="m16 16 5 5" /></svg>
          <span className={styles.query}>{t.query}</span>
        </div>
        <div className={panel.line} />
        <div className={styles.rows}>
          {t.rows.map((row, index) => <div className={`${styles.row} ${index === 1 ? styles.offline : ''}`} key={row.name}>
            {index === 0 ? <span className={styles.thumbnail}><i /><i /><i /><i /></span>
              : index === 2 ? <span className={styles.photo}><i /></span>
              : <Icon name="file" className={styles.icon} />}
            <div className={styles.text}>
              <div className={styles.name}><Highlight text={row.name} /></div>
              <div className={styles.detail}><Highlight text={row.detail} /></div>
            </div>
            <span className={styles.date}>{row.date}</span>
          </div>)}
        </div>
      </div>
      <p className={styles.srOnly}>{t.demoDescription}</p>
    </div>
    {standalone && <>
      <div className={styles.features}>
        {t.features.map(feature => <div key={feature.title}><h3>{feature.title}</h3><p>{feature.description}</p></div>)}
      </div>
      <p className={styles.privacy}>{t.privacy}</p>
    </>}
  </section>;
}
