import { defineConfig } from 'vite';
import { resolve } from 'node:path';

export default defineConfig({
  base: '/',
  build: {
    outDir: resolve(import.meta.dirname, '../Sources/ModelViewer/Resources/Web'),
    emptyOutDir: true,
    target: 'es2022',
    chunkSizeWarningLimit: 1600,
  },
});
