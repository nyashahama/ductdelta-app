import { createHash } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'

// Static prerender output has a fixed bootstrap. Hash it so the Rust server
// can keep its default policy for all other inline scripts.
const directory = new URL('../dist/client/', import.meta.url)
const html = await readFile(new URL('_shell.html', directory), 'utf8')
const hashes = new Set()
for (const [, script] of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)) {
  if (script.trim()) hashes.add(createHash('sha256').update(script.replace(/\r\n?/g, '\n')).digest('base64'))
}
await writeFile(new URL('script-hashes.txt', directory), [...hashes].join('\n') + '\n')
