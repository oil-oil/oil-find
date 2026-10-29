import { Privacy } from '@/components/Privacy';
import { siteMetadata } from '@/lib/metadata';

export const metadata = siteMetadata('zh', 'privacy');
export default function Page() { return <Privacy lang="zh" />; }
