import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { createHash } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'

const directory = new URL('../.output/public/', import.meta.url)

function digest(content) {
  return createHash('sha256').update(content.replace(/\r\n?/g, '\n')).digest('base64')
}

async function writePolicyHashes(folder, pages, generatedStyles = []) {
  const scripts = new Set()
  const styles = new Set(generatedStyles.map(digest))
  for (const page of pages) {
    const html = await readFile(new URL(page, folder), 'utf8')
    for (const [, attributes, script] of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
      if (script.trim() && !/\btype=["']application\/json["']/i.test(attributes)) {
        scripts.add(digest(script))
      }
    }
    for (const [, style] of html.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/gi)) {
      if (style.trim()) styles.add(digest(style))
    }
  }
  await Promise.all([
    writeFile(new URL('script-hashes.txt', folder), [...scripts].join('\n') + '\n'),
    writeFile(new URL('style-hashes.txt', folder), [...styles].join('\n') + '\n')
  ])
}

await writePolicyHashes(directory, ['workspace/index.html'])

const marketing = new URL('marketing/', directory)
await mkdir(marketing, { recursive: true })
execFileSync('tar', [
  '-xzf', fileURLToPath(new URL('../marketing/public-site.tar.gz', import.meta.url)),
  '-C', fileURLToPath(marketing)
])
