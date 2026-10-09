import { Recover } from '@/components/Recover';
import { siteMetadata } from '@/lib/metadata';

export const metadata = siteMetadata('en', 'recover');
export default function Page() { return <Recover lang="en" />; }
