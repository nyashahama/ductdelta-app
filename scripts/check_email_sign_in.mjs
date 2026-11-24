import assert from 'node:assert/strict'
import { createInterface } from 'node:readline'
import { pathToFileURL } from 'node:url'

const { chromium } = await import(pathToFileURL(process.env.DUCTDELTA_PLAYWRIGHT_MODULE).href)
const { DD_EMAIL_ORIGIN: origin, DD_EMAIL_SETUP: setup, DD_EMAIL_LEGACY: legacy } = process.env
const input = createInterface({ input: process.stdin })
const browser = await chromium.launch({ executablePath: process.env.DUCTDELTA_CHROME ?? '/usr/bin/google-chrome' })
const button = (page, name) => page.getByRole('button', { name, exact: true })
const field = (page, name) => page.getByLabel(name, { exact: true })
const heading = (page, name) => page.getByRole('heading', { name, exact: true })
const errors = []

async function page(options) {
  const context = await browser.newContext(options)
  const tab = await context.newPage()
  tab.setDefaultTimeout(10000)
  tab.on('pageerror', error => errors.push(error.message))
  return tab
}

async function enterEmail(tab, email) {
  await field(tab, 'Email address').fill(email)
  const queued = tab.waitForResponse(response => response.url() === origin + '/api/account/email-codes')
  await button(tab, 'Email me a code').click()
  const response = await queued
  assert.equal(response.status(), 202, await response.text())
  const { id } = await response.json()
  await heading(tab, 'Enter your sign-in code').waitFor()
  const reply = new Promise(resolve => input.once('line', resolve))
  console.log(JSON.stringify({ id, email }))
  const code = await reply
  assert.match(code, /^[0-9]{8}$/)
  const codeField = field(tab, 'Sign-in code')
  assert.equal(await codeField.getAttribute('autocomplete'), 'one-time-code')
  await codeField.fill(code)
  const verification = tab.waitForResponse(response => response.url() === origin + '/api/account/email-codes/verify')
  await button(tab, 'Continue').click()
  assert.equal((await verification).status(), 204)
}

try {
  const owner = await page({ viewport: { width: 1280, height: 900 } })
  await owner.goto(origin)
  await heading(owner, 'Sign in to your workspace').waitFor()
  assert.equal(await owner.getByLabel('Access key', { exact: true }).count(), 0)
  await button(owner, 'Create a company').click()
  await field(owner, 'Company name').fill('Browser Mechanical')
  await field(owner, 'Your name').fill('Site Owner')
  await field(owner, 'Company setup code').fill(setup)
  await enterEmail(owner, 'browser-owner@example.test')
  await heading(owner, 'Projects').waitFor()
  await field(owner, 'Project name').fill('Browser plantroom')
  await button(owner, 'Create project').click()
  await owner.getByRole('link', { name: 'Browser plantroom', exact: true }).waitFor()
  await field(owner, 'Invitee name').fill('Mobile Member')
  await button(owner, 'Create invitation').click()
  const inviteLink = field(owner, 'Invitation link')
  await inviteLink.waitFor()

  const phone = { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true }
  const member = await page(phone)
  await member.goto(await inviteLink.inputValue())
  await heading(member, 'Join the company').waitFor()
  await member.waitForFunction(() => !location.hash)
  await enterEmail(member, 'browser-member@example.test')
  await member.getByText('Your account has no assigned projects.', { exact: true }).waitFor()
  assert.equal((await (await member.request.get(origin + '/api/session')).json()).name, 'Mobile Member')
  assert.ok(await member.evaluate(() => document.documentElement.scrollWidth <= innerWidth))

  const returning = await page(phone)
  await returning.goto(origin)
  await enterEmail(returning, 'browser-member@example.test')
  await returning.getByText('Your account has no assigned projects.', { exact: true }).waitFor()
  assert.equal((await (await returning.request.get(origin + '/api/session')).json()).name, 'Mobile Member')

  const existing = await page()
  await existing.goto(origin)
  await button(existing, 'Use an existing key').click()
  await field(existing, 'Access or recovery key').fill(legacy)
  await enterEmail(existing, 'browser-legacy@example.test')
  await heading(existing, 'Project overview').waitFor()
  assert.deepEqual(errors, [])
  console.log('PASS: Chromium verifies company setup, mobile invitation, returning sign-in and existing-account migration using delivered codes')
} finally {
  input.close()
  await browser.close()
}
