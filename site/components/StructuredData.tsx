import { type Language } from '@/content/dict';
import { pageStructuredData, serializeStructuredData } from '@/lib/structured-data';

export function StructuredData({ lang, page }: { lang: Language; page: 'home' | 'pro' }) {
  return <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: serializeStructuredData(pageStructuredData(lang, page)) }} />;
}
