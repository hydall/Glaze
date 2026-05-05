import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
import { fileURLToPath, URL } from 'node:url';
import fs from 'node:fs';

// Получаем версию из package.json
const appVersion = (() => {
  try {
    const pkg = JSON.parse(fs.readFileSync(new URL('./package.json', import.meta.url), 'utf8'));
    return pkg.version ?? '0.0.0';
  } catch { return '0.0.0'; }
})();

export default defineConfig({
  plugins: [vue()],
  base: './', // Это ГЛАВНОЕ: заставляет пути быть относительными
  server: {
    host: true,
    proxy: {
      '/dc-proxy': {
        target: 'https://datacat.run',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/dc-proxy/, ''),
        configure: (proxy) => {
          proxy.on('proxyReq', (proxyReq) => {
            proxyReq.setHeader('Origin', 'https://datacat.run');
            proxyReq.setHeader('Referer', 'https://datacat.run/');
          });
        }
      }
    }
  },
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url))
    }
  },
  define: {
    __APP_VERSION__: JSON.stringify(appVersion)
  },
  build: {
    outDir: 'dist', // Куда собирать билд
  },
  worker: {
    format: 'es'
  }
})