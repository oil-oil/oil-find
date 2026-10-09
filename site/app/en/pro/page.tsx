import { Pro } from '@/components/Pro';
import { siteMetadata } from '@/lib/metadata';

export const metadata = siteMetadata('en', 'pro');
export default function Page() { return <Pro lang="en" />; }
