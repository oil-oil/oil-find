'use client';

import { useMemo, useState, type FormEvent } from 'react';
import { dict, type Language } from '@/content/dict';
import { demoFiles, match, parse } from '@/content/demo';
import styles from './ScopeDemo.module.css';

const ENGINE_URLS = {
  DuckDuckGo: 'https://duckduckgo.com/?q=',
  Google: 'https://www.google.com/search?q=',
  Bing: 'https://www.bing.com/search?q=',
} as const;

export function ScopeDemo({ lang }: { lang: Language }) {
  const t = dict[lang];
  const [scope, setScope] = useState(0), [query, setQuery] = useState('readme');
  const [engine, setEngine] = useState<keyof typeof ENGINE_URLS>('DuckDuckGo');
  const files = useMemo(() => demoFiles(lang).filter(file => match(file, parse(query), null)), [lang, query]);

  function submitSearch(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!query.trim()) return;
    window.open(ENGINE_URLS[engine] + encodeURIComponent(query.trim()), '_blank', 'noopener,noreferrer');
  }

  return <section className={`col sect ${styles.section}`} id="scopes">
    <h2>{t.scopeTitle}</h2><p className="sub">{t.scopeSubtitle}</p>
    <div className={`sheet ${styles.card}`}>
      <nav className={styles.tabs} aria-label={t.scopeTitle}>
        {t.scopeTabs.map((label, index) => <button type="button" key={label} aria-pressed={scope === index} className={scope === index ? styles.active : ''} onClick={() => setScope(index)}>{label}</button>)}
      </nav>
      <div className={styles.body}>
        {scope === 0 && <ul className={styles.items}>{t.scopeAllItems.map(item => <li key={item}><b>{item.split(' · ')[0]}</b><span>{item.split(' · ')[1]}</span></li>)}</ul>}
        {scope === 1 && <ul className={styles.items}>{t.scopeApps.map(item => <li key={item}><b>{item.split(' · ')[0]}</b><span>{item.split(' · ')[1]}</span></li>)}</ul>}
        {scope === 2 && <>
          <label className={styles.field}>{t.placeholder}<input value={query} onChange={event => setQuery(event.target.value)} /></label>
          <ul className={styles.items}>{files.slice(0, 4).map(file => <li key={`${file.dir}/${file.name}`}><b>{file.name}</b><span>{file.dir}</span></li>)}</ul>
        </>}
        {scope === 3 && <ul className={styles.items}>{t.scopeSettings.map(item => <li key={item}><b>{item.split(' · ')[0]}</b><span>{item.split(' · ')[1]}</span></li>)}</ul>}
        {scope === 4 && <><ul className={styles.items}>{t.scopeClips.map(item => <li key={item}><b>{item}</b><span>{t.scopeSampleTag}</span></li>)}</ul><p className={styles.note}>{t.scopeClipboardNote}</p></>}
        {scope === 5 && <><label className={styles.field}>{t.scopeCalcLabel}<input value="12 × 8 + 5" readOnly /></label><p className={styles.result}>{t.scopeCalcResult}<b>101</b></p><p className={styles.note}>{t.scopeOfflineNote}</p></>}
        {scope === 6 && <>
          <form className={styles.form} onSubmit={submitSearch}>
            <label className={styles.field}>{t.scopeWebLabel}<input value={query} onChange={event => setQuery(event.target.value)} /></label>
            <label className={styles.select}>{t.scopeEngineLabel}<select value={engine} onChange={event => setEngine(event.target.value as keyof typeof ENGINE_URLS)}>{t.scopeEngines.map(value => <option key={value}>{value}</option>)}</select></label>
            <button className={styles.submit} type="submit">{t.scopeSubmit}</button>
          </form>
          <p className={styles.note}>{t.scopeOfflineNote}</p>
          <a className={styles.url} href="https://example.com/research" target="_blank" rel="noreferrer">{t.scopeUrlLabel}: {t.scopeUrlOpen}</a>
        </>}
      </div>
      <footer className={styles.footer}>{lang === 'zh' ? '网站合成数据演示' : 'Synthetic website demo'} · {t.scopeKeyboard}</footer>
    </div>
  </section>;
}
