'use client';

import { Fragment, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type MouseEvent } from 'react';
import { commonCopy, dict, type Language } from '@/content/dict';
import { demoFiles, KINDS, match, parse, RUN } from '@/content/demo';
import { Icon } from './Icon';
import { useSearchActions } from './SearchContext';
import { isShortcut } from './motion';
import styles from './SearchPanel.module.css';

const ROW = 50;
// Pause after each replayed keystroke, uneven like a person typing "readme".
const CADENCE = [240, 150, 190, 130, 170];
const reduced = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
const escapeHTML = (text: string) => text.replace(/[&<>]/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' })[character]!);
function highlight(name: string, terms: string[]): string {
  const lower = name.toLowerCase(), spans: [number, number][] = [];
  for (const term of terms) for (let index = lower.indexOf(term); index >= 0; index = lower.indexOf(term, index + 1)) spans.push([index, index + term.length]);
  spans.sort((a, b) => a[0] - b[0]);
  let output = '', at = 0;
  for (const [start, end] of spans) {
    if (start < at) continue;
    output += escapeHTML(name.slice(at, start)) + '<mark>' + escapeHTML(name.slice(start, end)) + '</mark>'; at = end;
  }
  return output + escapeHTML(name.slice(at));
}

export function SearchPanel({ lang }: { lang: Language }) {
  const t = dict[lang], { register } = useSearchActions();
  const [raw, setRaw] = useState(''), [chip, setChip] = useState(0), [selected, setSelected] = useState(0);
  const [hover, setHover] = useState(-1);
  const [selectionFromPointer, setSelectionFromPointer] = useState(false);
  const [measurement, setMeasurement] = useState<string | null>(null), [toastText, setToastText] = useState<string | null>(null);
  const input = useRef<HTMLInputElement>(null), panel = useRef<HTMLElement>(null), list = useRef<HTMLDivElement>(null), rows = useRef<HTMLDivElement>(null);
  const selectionPlate = useRef<HTMLDivElement>(null);
  const pill = useRef<HTMLSpanElement>(null), chipButtons = useRef<(HTMLButtonElement | null)[]>([]), currentChip = useRef(chip), placed = useRef(false);
  const replayTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined), toastTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined), replaying = useRef(false);
  currentChip.current = chip;
  const files = useMemo(() => demoFiles(lang), [lang]), query = useMemo(() => parse(raw), [raw]);
  const home = query.empty && !KINDS[chip];
  const results = useMemo(() => files.filter(file => match(file, query, KINDS[chip])), [files, query, chip]);
  const count = home ? t.home.length : results.length;
  const status = measurement ? t.statusReplay(measurement) : home ? t.statusHome(count) : t.statusDemo(count);

  const stopReplay = useCallback(() => { replaying.current = false; clearTimeout(replayTimer.current); }, []);
  const search = useCallback((text: string) => {
    setRaw(text); setSelected(0); setHover(-1); setMeasurement(null);
    if (list.current) list.current.scrollTop = 0;
  }, []);
  const fill = useCallback((text: string) => { stopReplay(); setChip(0); search(text); input.current?.focus(); }, [stopReplay, search]);
  const placePill = useCallback((animate: boolean) => {
    const button = chipButtons.current[currentChip.current], element = pill.current;
    if (!button || !element) return;
    const left = button.offsetLeft, width = button.offsetWidth;
    if (!animate) element.style.transition = 'none';
    element.style.left = `${left}px`; element.style.width = `${width}px`;
    if (!animate) { void element.offsetWidth; element.style.transition = ''; }
  }, []);
  useLayoutEffect(() => { placePill(placed.current); placed.current = true; }, [chip, placePill]);
  useLayoutEffect(() => {
    if (!selectionFromPointer) return;
    // Commit the pointer target without a transition before restoring keyboard motion.
    if (selectionPlate.current) void selectionPlate.current.offsetHeight;
    setSelectionFromPointer(false);
  }, [selectionFromPointer, selected]);
  useEffect(() => {
    const resize = () => placePill(false);
    window.addEventListener('resize', resize);
    return () => window.removeEventListener('resize', resize);
  }, [placePill]);
  useEffect(() => register(text => {
    fill(text); panel.current?.scrollIntoView({ behavior: reduced() ? 'auto' : 'smooth', block: 'center' });
  }), [fill, register]);
  useEffect(() => {
    const initial = new URLSearchParams(location.search).get('q');
    replaying.current = !reduced() && !initial;
    if (initial) search(initial);
    const replay = (index: number) => {
      if (!replaying.current) return;
      if (index === RUN.length) {
        replayTimer.current = setTimeout(() => {
          if (!replaying.current) return;
          search(''); replayTimer.current = setTimeout(() => replay(0), 2200);
        }, 3400);
        return;
      }
      const [text, hits] = RUN[index];
      search(text); setMeasurement(hits);
      replayTimer.current = setTimeout(() => replay(index + 1), CADENCE[index]);
    };
    if (replaying.current) replayTimer.current = setTimeout(() => replay(0), 1700);
    const shortcut = (event: KeyboardEvent) => {
      if (!isShortcut(event)) return;
      event.preventDefault(); stopReplay();
      const element = panel.current!;
      if (!reduced()) {
        element.style.setProperty('--rise-delay', '.12s'); element.classList.remove(styles.rise);
        void element.offsetWidth; element.classList.add(styles.rise);
      }
      element.scrollIntoView({ behavior: reduced() ? 'auto' : 'smooth', block: 'center' });
      input.current?.focus({ preventScroll: true }); input.current?.select();
    };
    const media = matchMedia('(prefers-reduced-motion: reduce)');
    const change = () => { if (media.matches) stopReplay(); };
    window.addEventListener('keydown', shortcut); media.addEventListener('change', change);
    return () => { stopReplay(); clearTimeout(toastTimer.current); window.removeEventListener('keydown', shortcut); media.removeEventListener('change', change); };
  }, [lang, search, stopReplay]);

  function select(index: number, reveal = true) {
    const next = Math.max(0, Math.min(count - 1, index)); setSelected(next);
    if (reveal && list.current) {
      const top = next * ROW, bottom = top + ROW + 6;
      if (top < list.current.scrollTop) list.current.scrollTop = top;
      else if (bottom > list.current.scrollTop + list.current.clientHeight) list.current.scrollTop = bottom - list.current.clientHeight;
    }
  }
  function setFilter(index: number) { setChip((index + t.chips.length) % t.chips.length); search(raw); }
  function open(index = selected) {
    if (!count) return;
    if (!home) {
      clearTimeout(toastTimer.current); setToastText(t.toastDemo);
      toastTimer.current = setTimeout(() => setToastText(null), 2200); return;
    }
    const action = t.home[index]?.act;
    if (!action) return;
    if (action.href) location.href = action.href;
    else if (action.fill) fill(action.fill);
    else if (action.scroll) document.getElementById(action.scroll)?.scrollIntoView({ behavior: reduced() ? 'auto' : 'smooth', block: 'start' });
  }
  function rowIndex(event: MouseEvent): number { return Math.floor((event.clientY - rows.current!.getBoundingClientRect().top) / ROW); }
  function whenText(value: string): string {
    if (value[0] === 't') return t.today(value.slice(1));
    if (value[0] === 'y') return t.yesterday(value.slice(1));
    const [month, day] = value.slice(1).split('-').map(Number); return t.date(month, day);
  }
  function sizeText(value: string): string {
    if (value === 'folder') return t.folder;
    if (value === 'app') return t.app;
    return value[0] === 'b' ? t.bytes(value.slice(1)) : value;
  }

  return <section className={`${styles.panel} ${styles.rise}`} id="panel" ref={panel} aria-label={commonCopy.brand}>
    <div className={styles.search}>
      <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round"><circle cx="8.6" cy="8.6" r="5.9" /><path d="M13.1 13.1 17.4 17.4" /></svg>
      <input ref={input} id="q" value={raw} placeholder={t.placeholder} autoComplete="off" autoCapitalize="off" spellCheck={false} aria-label={commonCopy.searchLabel}
        onChange={event => { stopReplay(); search(event.target.value); }} onMouseDown={stopReplay}
        onKeyDown={event => {
          if (event.nativeEvent.isComposing) return;
          stopReplay();
          if (event.key === 'ArrowDown') { event.preventDefault(); select(selected + 1); }
          else if (event.key === 'ArrowUp') { event.preventDefault(); select(selected - 1); }
          else if (event.key === 'Tab') { event.preventDefault(); setFilter(chip + (event.shiftKey ? -1 : 1)); }
          else if (event.key === 'Enter') { event.preventDefault(); open(); }
          else if (event.key === 'Escape' && raw) { event.preventDefault(); search(''); }
        }} />
    </div><div className={styles.line} />
    <div className={styles.chips} id="chips"><span className={styles.pill} id="pill" ref={pill} />
      {t.chips.map((label, index) => <button className={`${styles.chip}${index === chip ? ` ${styles.on}` : ''}`} type="button" tabIndex={-1} key={label} ref={element => { chipButtons.current[index] = element; }} onMouseDown={event => { event.preventDefault(); stopReplay(); setFilter(index); input.current?.focus(); }}>{label}</button>)}
      <span className={styles.sort} id="sort">{t.sort}</span>
    </div>
    <div className={styles.list} id="list" ref={list} onScroll={() => setHover(-1)}>
      <div className={styles.rows} id="rows" ref={rows} style={{ height: `${count * ROW + 6}px` }}
        onMouseMove={event => { const index = rowIndex(event); setHover(index >= 0 && index < count ? index : -1); }} onMouseLeave={() => setHover(-1)}
        onMouseDown={event => { const index = rowIndex(event); if (index < 0 || index >= count) return; event.preventDefault(); stopReplay(); input.current?.focus(); setSelectionFromPointer(true); select(index); setHover(-1); }}
        onClick={event => { const index = rowIndex(event); if (index >= 0 && index < count && home) open(index); }} onDoubleClick={() => { if (!home) open(); }}>
        {count > 0 && <>
          <div className={`${styles.plate} ${styles.hov}`} id="hov" style={{ transform: `translateY(${Math.max(0, hover) * ROW}px)`, opacity: hover < 0 || hover === selected ? 0 : 1 }} />
          <div className={`${styles.plate} ${styles.sel}${selectionFromPointer ? ` ${styles.pointerSelection}` : ''}`} id="sel" ref={selectionPlate} style={{ transform: `translateY(${selected * ROW}px)` }} />
          {home ? t.home.map((item, index) => <div className={styles.row} style={{ transform: `translateY(${index * ROW}px)` }} key={`home-${index}`}>
            <Icon name={item.icon} className={styles.ico} /><div className={styles.name}>{item.name}</div><div className={styles.path} dangerouslySetInnerHTML={{ __html: item.path }} /><div className={styles.meta}>{item.meta}</div>{item.meta2 && <div className={styles.meta2}>{item.meta2}</div>}
          </div>) : results.map((file, index) => <div className={styles.row} style={{ transform: `translateY(${index * ROW}px)` }} key={`${file.dir}/${file.name}`}>
            <Icon name={file.kind === 'folder' || file.kind === 'app' ? file.kind : 'file'} className={styles.ico} /><div className={styles.name} dangerouslySetInnerHTML={{ __html: highlight(file.name, query.pos) }} /><div className={styles.path}>{file.dir}</div><div className={styles.meta}>{whenText(file.when)}</div><div className={styles.meta2}>{sizeText(file.size)}</div>
          </div>)}
        </>}
      </div>
      {!count && <div className={styles.none}><Icon name="none" empty /><b>{t.noneTitle}</b><span>{t.noneBody}</span></div>}
    </div><div className={styles.line} />
    <div className={styles.foot}><span id="status" className={`${styles.status}${toastText ? ` ${styles.toast}` : ''}`}>{toastText ?? status}</span><span className={styles.sp} /><span className={styles.hints} id="hints">{t.hints.map(([key, label], index) => <Fragment key={key}>{index > 0 && '　'}<kbd>{key}</kbd>{label}</Fragment>)}</span></div>
  </section>;
}
