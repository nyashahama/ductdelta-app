import assert from 'node:assert/strict'
import { pathToFileURL } from 'node:url'

const { chromium } = await import(pathToFileURL(process.env.DUCTDELTA_PLAYWRIGHT_MODULE).href)
const { DD_ENTRA_ORIGIN: origin, DD_ENTRA_COMPANY: company } = process.env
const browser = await chromium.launch({ executablePath: process.env.DUCTDELTA_CHROME ?? '/usr/bin/google-chrome' })

try {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true })
  const page = await context.newPage()
  const errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.goto(origin + '/?sso=' + company)
  await page.getByRole('button', { name: 'Sign in with Microsoft', exact: true }).click()
  await page.getByRole('heading', { name: 'Project overview', exact: true }).waitFor()
  assert.equal(page.url(), origin + '/workspace/')
  const team = await page.request.get(origin + '/api/companies/' + company + '/team')
  assert.equal(team.status(), 200)
  await page.goto(origin + '/?view=security')
  await page.getByRole('button', { name: 'Sign in with Microsoft for Entra Mechanical' }).waitFor()
  assert.deepEqual(errors, [])
  console.log('PASS: mobile Chromium crosses to the Entra provider and returns to an MFA-authorized workspace')
} finally {
  await browser.close()
}
