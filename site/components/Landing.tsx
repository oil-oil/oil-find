import Image from 'next/image';
import { dict, GITHUB_URL, type Language } from '@/content/dict';
import { TopBar } from './TopBar';
import { SearchPanel } from './SearchPanel';
import { SpeedTrace } from './SpeedTrace';
import { SyntaxSheet } from './SyntaxSheet';
import { ProSection } from './ProSection';
import { SiteFooter } from './SiteFooter';
import { SearchProvider } from './SearchContext';
import styles from './Landing.module.css';
import { StructuredData } from './StructuredData';
import { AITopicsSection } from './AITopicsSection';
import { aiTopicsCopy } from '@/content/ai-topics';

export function Landing({ lang }: { lang: Language }) {
  const t = dict[lang];
  return <><StructuredData lang={lang} page="home" /><TopBar lang={lang} /><main><SearchProvider>
    <section className={styles.hero}>
      <div className={styles.intro}>
        <Image className={styles.appIcon} src="/assets/icon.png" width={80} height={80} alt="" unoptimized />
        <h1 className={styles.headline}>{t.lead.map(part => <span key={part}>{part}</span>)}</h1>
        <p className={styles.summary}>{aiTopicsCopy[lang].hero}</p>
        <a className={styles.download} href="/downloads/Oil-Find.zip">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M12 3v12m-5-5 5 5 5-5M5 16v4h14v-4" /></svg>
          <span>{t.dl}</span>
        </a>
        <p className={styles.reassurance}>{t.downloadNote}</p>
        <a className={styles.sourceLink} href={GITHUB_URL}>{t.openSource} ↗</a>
      </div>
      <div className={styles.preview}><SearchPanel lang={lang} /></div>
    </section>
    <SpeedTrace lang={lang} /><AITopicsSection lang={lang} /><SyntaxSheet lang={lang} /><ProSection lang={lang} />
  </SearchProvider></main><SiteFooter lang={lang} /></>;
}
