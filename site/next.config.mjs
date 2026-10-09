/** @type {import('next').NextConfig} */
const config = {
  async headers() {
    return [
      { source: '/downloads/:path*', headers: [{ key: 'Cache-Control', value: 'public, max-age=300' }] },
      { source: '/updates/latest.json', headers: [{ key: 'Cache-Control', value: 'no-cache' }] },
    ];
  },
};
export default config;
