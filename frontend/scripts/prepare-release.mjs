import { createHash } from 'node:crypto'
import { readFile, writeFile } from 'node:fs/promises'

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

// Nuxt UI prerenders the selected palette as inline CSS.
await writePolicyHashes(directory, ['index.html'])

// ScrewFast temporarily inserts this rule while switching themes.
await writePolicyHashes(new URL('product/', directory),
  ['index.html', 'workflow/index.html', 'example/index.html', 'faq/index.html'],
  ['*{transition: unset !important;}'])
