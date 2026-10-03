import { createAssetServer } from 'remix/assets'

const isDevelopment = (process.env.NODE_ENV ?? 'development') === 'development'

export const assets = createAssetServer({
  basePath: '/assets',
  rootDir: process.cwd(),

  allowFiles: ['app/routes.ts', 'app/**/public/**'],
  allowPackages: ['remix'],
  denyFiles: ['app/**/*.test.*'],
  sourceMaps: isDevelopment ? 'external' : undefined,
  minify: !isDevelopment,
  watch: isDevelopment,
})

export const scriptEntry = await assets.getScriptEntry('app/actions/public/entry.ts')
