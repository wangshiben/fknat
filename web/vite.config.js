import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  root: 'src',
  plugins: [react()],
  build: {
    outDir: '../dist',
    emptyOutDir: true,
    rollupOptions: {
      output: {
        entryFileNames: 'app.js',
        assetFileNames: asset => asset.name?.endsWith('.css') ? 'app.css' : '[name][extname]'
      }
    }
  }
});
