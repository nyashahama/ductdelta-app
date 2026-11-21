import { createHash } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'

const directory = new URL('../.output/public/', import.meta.url)
const html = await readFile(new URL('index.html', directory), 'utf8')

function digest(content) {
  return createHash('sha256').update(content.replace(/\r\n?/g, '\n')).digest('base64')
}

const scripts = new Set()
for (const [, attributes, script] of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
  if (script.trim() && !/\btype=["']application\/json["']/i.test(attributes)) {
    scripts.add(digest(script))
  }
}

// Nuxt UI prerenders the selected palette as inline CSS.
const styles = new Set([...html.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/gi)]
  .map(([, style]) => style).filter(style => style.trim()).map(digest))

await Promise.all([
  writeFile(new URL('script-hashes.txt', directory), [...scripts].join('\n') + '\n'),
  writeFile(new URL('style-hashes.txt', directory), [...styles].join('\n') + '\n')
])
