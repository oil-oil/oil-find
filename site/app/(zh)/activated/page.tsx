import { Activated } from '@/components/Activated';
import { siteMetadata } from '@/lib/metadata';

export const metadata = siteMetadata('zh', 'activated');
export default function Page() { return <Activated lang="zh" />; }
