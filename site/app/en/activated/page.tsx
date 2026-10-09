import { Activated } from '@/components/Activated';
import { siteMetadata } from '@/lib/metadata';

export const metadata = siteMetadata('en', 'activated');
export default function Page() { return <Activated lang="en" />; }
