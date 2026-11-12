import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

// Unbound Muzik — fresh rebuild, 2026-11-11.
// Static PWA. No server code here. Search goes through one configurable
// proxy endpoint (see src/lib/youtube.ts) — the proxy itself is Phase 2.
export default defineConfig({
  // GitHub Pages serves the project site at /Unbound-Muzik/, so every
  // built path is rooted there. Without this, the app would load blank
  // on Pages (root-absolute /assets/... links would 404).
  base: '/Unbound-Muzik/',
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['favicon.svg', 'icon-192.png', 'icon-512.png', 'icon-512-maskable.png'],
      manifest: {
        name: 'Unbound Muzik',
        short_name: 'Unbound',
        description: 'Music, unbound from the ridiculousness. Personal player, free and ad-free forever.',
        theme_color: '#050505',
        background_color: '#050505',
        display: 'standalone',
        orientation: 'portrait',
        start_url: '/Unbound-Muzik/',
        icons: [
          {
            src: 'favicon.svg',
            sizes: 'any',
            type: 'image/svg+xml',
            purpose: 'any',
          },
          {
            src: 'icon-192.png',
            sizes: '192x192',
            type: 'image/png',
            purpose: 'any',
          },
          {
            src: 'icon-512.png',
            sizes: '512x512',
            type: 'image/png',
            purpose: 'any',
          },
          {
            src: 'icon-512-maskable.png',
            sizes: '512x512',
            type: 'image/png',
            purpose: 'maskable',
          },
        ],
      },
      workbox: {
        // Cache the app shell so the app opens offline. Music itself is
        // never cached by the service worker — it plays through the
        // YouTube IFrame player, which the browser handles.
        globPatterns: ['**/*.{js,css,html,svg,png}'],
      },
    }),
  ],
});
