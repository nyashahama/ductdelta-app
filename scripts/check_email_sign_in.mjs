import assert from 'node:assert/strict'
import { createInterface } from 'node:readline'
import { pathToFileURL } from 'node:url'

const { chromium } = await import(pathToFileURL(process.env.DUCTDELTA_PLAYWRIGHT_MODULE).href)
const { DD_EMAIL_ORIGIN: origin, DD_EMAIL_LEGACY: legacy } = process.env
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

async function enterEmail(tab, email, { reload = false, interrupted = false, emailLabel = 'Email address' } = {}) {
  await field(tab, emailLabel).fill(email)
  const codeUrl = origin + '/api/account/email-codes'
  const captured = Promise.withResolvers()
  if (interrupted) {
    await tab.route(codeUrl, async (route) => {
      try {
        captured.resolve(await route.fetch())
        await route.abort()
      } catch (error) {
        captured.reject(error)
      }
    }, { times: 1 })
  }
  const queued = interrupted ? captured.promise : tab.waitForResponse(response => response.url() === codeUrl)
  await button(tab, 'Email me a code').click()
  const response = await queued
  assert.equal(response.status(), 202, await response.text())
  const { id } = await response.json()
  await heading(tab, 'Enter your sign-in code').waitFor()
  const reply = new Promise(resolve => input.once('line', resolve))
  console.log(JSON.stringify({ id, email }))
  const code = await reply
  assert.match(code, /^[0-9]{8}$/)
  if (reload) {
    await tab.reload()
    await heading(tab, 'Enter your sign-in code').waitFor({ timeout: 3000 })
  }
  const codeField = field(tab, 'Sign-in code')
  assert.equal(await codeField.getAttribute('autocomplete'), 'one-time-code')
  await codeField.fill(code)
  const verification = tab.waitForResponse(response => response.url() === origin + '/api/account/email-codes/verify')
  await button(tab, 'Continue').click()
  assert.equal((await verification).status(), 204)
  await tab.waitForFunction(() => !sessionStorage.getItem('ductdelta-pending-email-code'))
}

try {
  const owner = await page({ viewport: { width: 1280, height: 900 } })
  await owner.goto(origin)
  await heading(owner, 'Sign in to your workspace').waitFor()
  assert.equal(await owner.getByLabel('Access key', { exact: true }).count(), 0)
  await button(owner, 'Create a company').click()
  await field(owner, 'Company name').fill('Browser Mechanical')
  await field(owner, 'Your name').fill('Site Owner')
  assert.equal(await field(owner, 'Company setup code').count(), 0)
  await enterEmail(owner, 'browser-owner@example.test', { reload: true })
  await heading(owner, 'Projects').waitFor()
  await owner.goto(origin)
  await owner.getByRole('link', { name: 'Create a project', exact: true }).click({ timeout: 4000 })
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
  await enterEmail(member, 'browser-member@example.test', { reload: true })
  await member.getByText('Your account has no assigned projects.', { exact: true }).waitFor()
  assert.equal(await member.getByRole('link', { name: 'Create a project', exact: true }).count(), 0)
  assert.equal((await (await member.request.get(origin + '/api/session')).json()).name, 'Mobile Member')
  assert.ok(await member.evaluate(() => document.documentElement.scrollWidth <= innerWidth))

  const returning = await page(phone)
  await returning.goto(origin)
  await enterEmail(returning, 'browser-member@example.test', { interrupted: true })
  await returning.getByText('Your account has no assigned projects.', { exact: true }).waitFor()
  assert.equal((await (await returning.request.get(origin + '/api/session')).json()).name, 'Mobile Member')

  const existing = await page()
  await existing.goto(origin)
  await button(existing, 'Use an existing key').click()
  await field(existing, 'Access or recovery key').fill(legacy)
  await enterEmail(existing, 'browser-legacy@example.test')
  await heading(existing, 'Project overview').waitFor()

  await owner.goto(origin + '/?view=security')
  await heading(owner, 'Account security').waitFor()
  await button(owner, 'Generate recovery code').click()
  const saved = await field(owner, 'Account recovery code').inputValue()
  assert.match(saved, /^[0-9a-f]{64}$/)
  await owner.getByRole('link', { name: 'Change sign-in email', exact: true }).click()
  await heading(owner, 'Restore account access').waitFor()
  await field(owner, 'Saved recovery code').fill(saved)
  await enterEmail(owner, 'browser-new-owner@example.test', { emailLabel: 'New email address', reload: true })
  await heading(owner, 'Account security').waitFor()
  await owner.getByText('browser-new-owner@example.test', { exact: true }).waitFor()
  await button(owner, 'Generate recovery code').waitFor()
  assert.deepEqual(errors, [])
  console.log('PASS: Chromium verifies setup, mobile invitation, interrupted sign-in, account migration and verified email recovery')
} finally {
  input.close()
  await browser.close()
}
