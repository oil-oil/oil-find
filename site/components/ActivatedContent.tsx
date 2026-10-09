'use client';

import styles from './Licensing.module.css';

import Image from 'next/image';
import { useEffect, useRef, useState } from 'react';
import { activatedCopy, commonCopy, pagePath, type Language } from '@/content/dict';

interface PaidSession { key: string; email: string; mailed: boolean }
export function Activated({ lang }: { lang: Language }) {
  const t = activatedCopy[lang];
  const [state, setState] = useState<'loading' | 'ok' | 'fail'>('loading');
  const [data, setData] = useState<PaidSession | null>(null), [copied, setCopied] = useState(false);
  const copyTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => {
    const controller = new AbortController();
    const sessionID = new URLSearchParams(location.search).get('session_id') ?? '';
    setState('loading'); setData(null);
    fetch(`/api/session?session_id=${encodeURIComponent(sessionID)}`, { cache: 'no-store', signal: controller.signal })
      .then(response => response.ok ? response.json() : Promise.reject())
      .then((value: PaidSession) => { if (!controller.signal.aborted) { setData(value); setState('ok'); } })
      .catch(() => { if (!controller.signal.aborted) setState('fail'); });
    return () => controller.abort();
  }, []);
  useEffect(() => () => clearTimeout(copyTimer.current), []);
  async function copy() {
    if (!data) return;
    try { await navigator.clipboard.writeText(data.key); } catch { return; }
    setCopied(true); clearTimeout(copyTimer.current);
    copyTimer.current = setTimeout(() => setCopied(false), 1600);
  }
  return <main className={styles.solo}>
    <div className="state" id="loading" hidden={state !== 'loading'}><div className="spin" role="status" aria-label={commonCopy.loadingLabel} /></div>
    <div className="state pop" id="ok" hidden={state !== 'ok'}>
      <Image className="mark" src="/assets/icon.png" alt="" width={84} height={84} unoptimized />
      <h1>{t['ok.h']}</h1><p>{t['ok.p']}</p>
      <a className="btn blue" id="activate" href={data ? `oilfind://activate?key=${encodeURIComponent(data.key)}` : '#'}>{t['ok.cta']}</a>
      <div className="keybox"><code id="key">{data?.key ?? ''}</code><button className="btn soft" id="copy" type="button" onClick={copy}>{copied ? t.copied : t['ok.copy']}</button></div>
      <p className="fine" id="mailed" hidden={!data}>{data ? data.mailed && data.email ? t.mailed(data.email) : t.notMailed : ''}</p>
      <p className="fine"><span>{t['ok.install']}</span>{' '}<a href="/downloads/Oil-Find.zip">{t['ok.download']}</a></p>
    </div>
    <div className="state pop" id="fail" hidden={state !== 'fail'}>
      <Image className="mark" src="/assets/icon.png" alt="" width={84} height={84} unoptimized />
      <h1>{t['fail.h']}</h1><p>{t['fail.p']}</p>
      <a className="btn dark" href={pagePath(lang, 'recover')}>{t['fail.cta']}</a>
      <p className="fine"><a href={pagePath(lang)}>{t['fail.home']}</a></p>
    </div>
  </main>;
}
