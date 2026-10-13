/** @type {import('next').NextConfig} */

// `npm run build:static` (SYNAPS_STATIC_EXPORT=1) emits a plain static site in out/ for the
// FastAPI backend to serve at "/" (SYNAPS_FRONTEND_DIST): /api stays same-origin and the NAS
// doesn't need a Node process. Default builds are unchanged and keep the /api proxy for
// `next start` / `next dev`.
const staticExport = process.env.SYNAPS_STATIC_EXPORT === '1';

const nextConfig = {
  // Never resize images through Next's optimizer: it would run on the NAS's Core 2 Duo
  images: { unoptimized: true },
  ...(staticExport
    ? {
        output: 'export',
        // Emit out/sync/index.html rather than out/sync.html: Starlette's
        // StaticFiles(html=True) serves directory index files, not "<path>.html"
        trailingSlash: true,
      }
    : {
        async rewrites() {
          return [
            {
              source: '/api/:path*',
              destination: 'http://localhost:8000/api/:path*',
            },
          ];
        },
      }),
};

module.exports = nextConfig;
