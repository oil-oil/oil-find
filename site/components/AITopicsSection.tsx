import Image from 'next/image';
import { aiTopicsCopy } from '@/content/ai-topics';
import type { Language } from '@/content/dict';
import styles from './AITopicsSection.module.css';

export function AITopicsSection({ lang }: { lang: Language }) {
  const t = aiTopicsCopy[lang];
  return <section className="col sect" id="ai-topics">
    <p className={styles.label}>{t.label}</p>
    <h2>{t.title}</h2>
    <p className="sub">{t.intro}</p>
    <div className={`sheet ${styles.details}`}>
      <ul className={styles.sources}>
        <li><Image src="/assets/topic-icons/claude.png" width={40} height={40} alt="" unoptimized />Claude Code</li>
        <li><Image src="/assets/topic-icons/codex.png" width={40} height={40} alt="" unoptimized />Codex</li>
        <li><Image src="/assets/topic-icons/workbuddy.png" width={40} height={40} alt="" unoptimized />WorkBuddy</li>
      </ul>
      <p>{t.sources}</p>
      <div className={styles.facts}><p>{t.settings}</p><p>{t.privacy}</p></div>
    </div>
  </section>;
}
