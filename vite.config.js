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

// Strip browser-specific headers so upstream Anthropic sees a plain HTTP client
// (mirrors what CapacitorHttp sends on native). Logs request/response for debugging.
function configureAnthropicProxy(proxy) {
  proxy.on('proxyReq', (proxyReq, req) => {
    for (const h of ['origin', 'referer', 'cookie', 'user-agent', 'accept', 'accept-encoding', 'accept-language',
                     'sec-fetch-site', 'sec-fetch-mode', 'sec-fetch-dest', 'sec-fetch-user',
                     'sec-ch-ua', 'sec-ch-ua-mobile', 'sec-ch-ua-platform']) {
      proxyReq.removeHeader(h);
    }
    //proxyReq.setHeader('user-agent', 'glaze-dev-proxy');
    console.log('[proxy →]', req.method, proxyReq.path);
    console.log('[proxy →] headers:', proxyReq.getHeaders());
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => {
      if (chunks.length) console.log('[proxy →] body:', Buffer.concat(chunks).toString());
    });
  });
  proxy.on('proxyRes', (proxyRes, req) => {
    console.log('[proxy ←]', proxyRes.statusCode, req.method, req.url);
    const chunks = [];
    proxyRes.on('data', c => chunks.push(c));
    proxyRes.on('end', () => {
      if (chunks.length) console.log('[proxy ←] body:', Buffer.concat(chunks).toString());
    });
  });
  proxy.on('error', (err) => console.log('[proxy ✗]', err.message));
}

export default defineConfig({
  plugins: [vue()],
  base: './',
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url))
    }
  },
  define: {
    __APP_VERSION__: JSON.stringify(appVersion)
  },
  server: {
    proxy: {
      '/anthropic/oauth/token': {
        target: 'https://console.anthropic.com',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/anthropic\/oauth\/token/, '/v1/oauth/token'),
        configure: configureAnthropicProxy
      },
      '/anthropic/v1': {
        target: 'https://api.anthropic.com',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/anthropic\/v1/, '/v1'),
        configure: configureAnthropicProxy
      }
    }
  },
  build: {
    outDir: 'dist', // Куда собирать билд
  },
  worker: {
    format: 'es'
  }
})