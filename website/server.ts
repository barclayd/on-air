import { router } from './app/router.ts'

const server = Bun.serve({
  port: Number(process.env.PORT ?? 44100),
  fetch: (request) => router.fetch(request),
})

console.log(`Server listening on ${server.url}`)
