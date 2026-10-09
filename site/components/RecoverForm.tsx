'use client';

import styles from './Licensing.module.css';

import { useEffect, useRef, useState, type FormEvent } from 'react';
import { commonCopy, recoverCopy, type Language } from '@/content/dict';

export function RecoverForm({ lang }: { lang: Language }) {
  const t = recoverCopy[lang], input = useRef<HTMLInputElement>(null);
  const [email, setEmail] = useState(''), [busy, setBusy] = useState(false), [sentEmail, setSentEmail] = useState<string | null>(null);
  const [message, setMessage] = useState({ text: '', error: false });
  const request = useRef<AbortController | null>(null), sending = useRef(false), selectAgain = useRef(false);
  useEffect(() => { input.current?.focus(); return () => request.current?.abort(); }, []);
  useEffect(() => { if (sentEmail === null && selectAgain.current) { input.current?.select(); selectAgain.current = false; } }, [sentEmail]);
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (sending.current) return;
    const address = email.trim(); setMessage({ text: '', error: false });
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(address)) { setMessage({ text: t.invalid, error: true }); input.current?.focus(); return; }
    sending.current = true; setBusy(true);
    const controller = new AbortController(); request.current = controller;
    try {
      const response = await fetch('/api/recover', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: address }), signal: controller.signal });
      if (response.ok) setSentEmail(address);
      else setMessage({ text: response.status === 501 ? t.unconfigured : t.offline, error: response.status !== 501 });
    } catch { if (!controller.signal.aborted) setMessage({ text: t.offline, error: true }); }
    if (!controller.signal.aborted) { sending.current = false; setBusy(false); }
  }
  return <main className={styles.solo}>
    <form className="state" id="form" noValidate hidden={sentEmail !== null} onSubmit={submit}>
      <h1>{t.h}</h1><p>{t.p}</p>
      <input className="field" id="email" ref={input} type="email" name="email" autoComplete="email" inputMode="email" placeholder={commonCopy.emailPlaceholder} aria-label={commonCopy.emailLabel} required value={email} onChange={event => setEmail(event.target.value)} />
      <button className="btn dark" id="send" type="submit" disabled={busy}>{busy ? t.sending : t.cta}</button>
      <p className={`msg${message.error ? ' err' : ''}`} id="msg" role="alert">{message.text}</p>
    </form>
    <div className="state pop" id="sent" hidden={sentEmail === null}>
      <h1>{t['sent.h']}</h1><p id="sentText">{sentEmail ? t.sent(sentEmail) : ''}</p>
      <p className="fine"><a href="#" id="again" onClick={event => { event.preventDefault(); selectAgain.current = true; setSentEmail(null); }}>{t['sent.again']}</a></p>
    </div>
  </main>;
}
