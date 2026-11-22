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

function property(styles, name) {
  const value = styles.match(new RegExp(`${name}:\\s*([^;}]+)`))?.[1]
  if (!value) throw new Error(`Workspace theme property ${name} is missing.`)
  return value.trim()
}

async function publishProductTheme(folder, pages) {
  const shell = await readFile(new URL('index.html', directory), 'utf8')
  const entry = shell.match(/href="\/(_nuxt\/entry\.[\w-]+\.css)"/)?.[1]
  if (!entry) throw new Error('Workspace stylesheet is missing from the built HTML.')
  const [workspace, fonts, product] = await Promise.all([
    readFile(new URL(entry, directory), 'utf8'),
    readFile(new URL('../app/assets/css/public-sans.css', import.meta.url), 'utf8'),
    readFile(new URL('product-dark.css', import.meta.url), 'utf8')
  ])
  // Nuxt UI prerenders the configured color aliases in the workspace shell.
  const color = (name) => {
    const alias = property(shell, `--ui-color-${name}`).match(/^var\((--color-[\w-]+)[,)]/)?.[1]
    if (!alias) throw new Error(`Workspace color alias ${name} is invalid.`)
    return property(workspace, alias)
  }
  const palette = [
    `--product-workspace-font: ${property(workspace, '--font-sans')};`,
    `--product-workspace-primary: ${color('primary-400')};`,
    ...[200, 300, 400, 500, 600, 700, 800, 900].map(
      shade => `--product-workspace-neutral-${shade}: ${color(`neutral-${shade}`)};`
    )
  ]
  const css = `${fonts}\nhtml.dark {\n  ${palette.join('\n  ')}\n}\n\n${product}`
  const hash = createHash('sha256').update(css).digest('hex').slice(0, 16)
  const asset = `_astro/workspace-dark.${hash}.css`
  const link = `<link rel="stylesheet" data-product-theme href="/product/${asset}">`
  await writeFile(new URL(asset, folder), css)
  for (const page of pages) {
    const file = new URL(page, folder)
    const html = await readFile(file, 'utf8')
    const previous = /<link rel="stylesheet" data-product-theme href="[^"]+">/
    await writeFile(file, previous.test(html) ? html.replace(previous, link) : html.replace('</head>', link + '</head>'))
  }
}

// Nuxt UI prerenders the selected palette as inline CSS.
await writePolicyHashes(directory, ['index.html'])

const product = new URL('product/', directory)
const productPages = ['index.html', 'workflow/index.html', 'example/index.html', 'faq/index.html']
await publishProductTheme(product, productPages)

// ScrewFast temporarily inserts this rule while switching themes.
await writePolicyHashes(product, productPages, ['*{transition: unset !important;}'])
