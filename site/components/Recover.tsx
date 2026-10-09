import type { Language } from '@/content/dict';
import { TopBar } from './TopBar';
import { RecoverForm } from './RecoverForm';

export function Recover({ lang }: { lang: Language }) {
  return <><TopBar lang={lang} page="recover" /><RecoverForm lang={lang} /></>;
}
