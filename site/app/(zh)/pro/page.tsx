import { Pro } from '@/components/Pro';
import { siteMetadata } from '@/lib/metadata';

export const metadata = siteMetadata('zh', 'pro');
export default function Page() { return <Pro lang="zh" />; }
