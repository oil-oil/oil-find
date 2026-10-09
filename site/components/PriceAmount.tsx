'use client';

import { useEffect, useState } from 'react';
import type { Language } from '@/content/dict';
import { loadPriceDisplay, visitorPrice } from '@/lib/price';
import styles from './ProSection.module.css';

export function PriceAmount({ lang }: { lang: Language }) {
  const fallback = visitorPrice(lang === 'zh' ? 'CN' : null).display;
  const [display, setDisplay] = useState(fallback);
  useEffect(() => {
    const controller = new AbortController();
    setDisplay(fallback);
    loadPriceDisplay(lang, controller.signal).then(price => {
      if (!controller.signal.aborted) setDisplay(price);
    });
    return () => controller.abort();
  }, [lang, fallback]);
  return <span className={styles.amount}>{display}</span>;
}
