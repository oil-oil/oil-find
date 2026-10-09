import type { MetadataRoute } from 'next';
import { siteURL } from '@/lib/metadata';

export default function robots(): MetadataRoute.Robots {
  return { rules: { userAgent: '*', allow: '/', disallow: '/api/' }, sitemap: `${siteURL}/sitemap.xml` };
}
