import type { Language } from '@/content/dict';
import { TopBar } from './TopBar';
import { Activated as ActivatedContent } from './ActivatedContent';

export function Activated({ lang }: { lang: Language }) {
  return <><TopBar lang={lang} page="activated" /><ActivatedContent lang={lang} /></>;
}
