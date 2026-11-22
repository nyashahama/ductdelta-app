import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'

const { chromium } = await import(pathToFileURL(process.env.DUCTDELTA_PLAYWRIGHT_MODULE).href)
const origin = process.env.DD_NOTICE_ORIGIN
const browser = await chromium.launch({ executablePath: process.env.DUCTDELTA_CHROME ?? '/usr/bin/google-chrome' })
const errors = []
const filename = download => download.suggestedFilename()

async function download(page, trigger) {
  const event = page.waitForEvent('download')
  await trigger.click()
  const file = await event
  return { name: filename(file), bytes: await readFile(await file.path()) }
}

try {
  const desktop = await browser.newContext({ viewport: { width: 1440, height: 1000 } })
  await desktop.addCookies([{ name: 'dd_session', value: process.env.DD_NOTICE_SESSION,
    url: origin, httpOnly: true, sameSite: 'Strict' }])
  const mobile = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true })
  const issuer = await desktop.newPage()
  const recipient = await mobile.newPage()
  for (const page of [issuer, recipient]) {
    page.setDefaultTimeout(6500)
    page.on('pageerror', error => errors.push(error.message))
  }
  await issuer.goto(`${origin}/?view=cases&project=${process.env.DD_NOTICE_PROJECT}&caseId=${process.env.DD_NOTICE_CASE}`)
  const copies = issuer.getByRole('region', { name: 'Issued notice copies', exact: true })
  await copies.getByRole('button', { name: 'Issue a copy', exact: true }).click()
  await copies.getByLabel('Recipient', { exact: true }).fill('Alex · Site consultant')
  await copies.getByLabel('Recipient-facing text', { exact: true }).fill('Café plantroom change.\nReview the revised route.')
  await copies.getByRole('button', { name: 'Issue version 1', exact: true }).click()
  const original = await download(issuer, copies.getByRole('link', { name: 'Download version 1', exact: true }))
  assert.equal(original.name, 'notice-version-1.txt')
  assert.ok(original.bytes.toString().includes('Alex · Site consultant'))
  assert.ok(original.bytes.toString().includes('Café plantroom change.\nReview the revised route.'))
  assert.ok(!original.bytes.toString().includes('Internal notice draft'))
  await copies.getByText(createHash('sha256').update(original.bytes).digest('hex'), { exact: true }).waitFor()
  await copies.getByRole('button', { name: 'Create recipient link for version 1', exact: true }).click()
  const link = await copies.getByLabel('Recipient link for version 1', { exact: true }).inputValue()
  assert.ok(/^#key=[0-9a-f]{64}$/.test(new URL(link).hash), 'Recipient key must be a hex fragment')
  const requests = []
  recipient.on('request', request => requests.push(request))
  await recipient.goto(link)
  await recipient.waitForFunction(() => !location.hash)
  await recipient.getByRole('heading', { name: 'Issued notice copy' }).waitFor()
  await recipient.screenshot({ path: 'artifacts/issued-notice-recipient.png', animations: 'disabled' })
  const actual = await download(recipient, recipient.getByRole('button', { name: 'Download issued copy', exact: true }))
  assert.equal(actual.name, original.name)
  assert.deepEqual(actual.bytes, original.bytes)
  assert.ok(requests.every(request => !request.url().includes('#key=') && !request.headers().referer))
  assert.ok(requests.every(request => new URL(request.url()).origin === origin))
  assert.equal((await mobile.cookies()).length, 0)
  assert.ok(await recipient.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
  assert.ok(await issuer.evaluate(() => document.documentElement.scrollWidth <= innerWidth))

  await copies.getByRole('button', { name: 'Issue a new version', exact: true }).click()
  await copies.getByLabel('Recipient-facing text', { exact: true }).fill('Version 2 reviewed message.')
  await copies.getByRole('button', { name: 'Issue version 2', exact: true }).click()
  const revised = await download(issuer, copies.getByRole('link', { name: 'Download version 2', exact: true }))
  assert.ok(revised.bytes.toString().includes('Supersedes copy: '))
  assert.ok(revised.bytes.toString().includes('Version 2 reviewed message.'))
  await copies.getByText('Superseded', { exact: true }).waitFor()
  const beforeRevocation = await download(recipient, recipient.getByRole('button', { name: 'Download issued copy', exact: true }))
  assert.deepEqual(beforeRevocation.bytes, original.bytes)

  await copies.getByRole('button', { name: 'Revoke recipient link for version 1', exact: true }).click()
  await copies.getByText('Recipient link revoked', { exact: true }).waitFor()
  await recipient.getByRole('button', { name: 'Download issued copy', exact: true }).click()
  await recipient.getByText('This recipient link is unavailable. Ask the sender for a current link.', { exact: true }).waitFor()
  assert.deepEqual(errors, [])
  await issuer.screenshot({ path: 'artifacts/issued-notice-staff.png', animations: 'disabled' })
  await recipient.screenshot({ path: 'artifacts/issued-notice-recipient-revoked.png', animations: 'disabled' })
  const field = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true })
  await field.addCookies(await desktop.cookies())
  const mobileIssuer = await field.newPage()
  await mobileIssuer.goto(issuer.url())
  const mobileCopies = mobileIssuer.getByRole('region', { name: 'Issued notice copies', exact: true })
  await mobileCopies.getByRole('link', { name: 'Download version 2', exact: true }).waitFor()
  assert.ok(await mobileIssuer.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
  await mobileCopies.screenshot({ path: 'artifacts/issued-notice-staff-mobile.png', animations: 'disabled' })
  console.log('PASS: browser issuance, exact desktop and mobile bytes, supersession, and link revocation')
} finally {
  await browser.close()
}
