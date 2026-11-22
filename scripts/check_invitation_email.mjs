import assert from 'node:assert/strict'
import { pathToFileURL } from 'node:url'

const { chromium } = await import(pathToFileURL(process.env.DUCTDELTA_PLAYWRIGHT_MODULE).href)
const browser = await chromium.launch({ executablePath: process.env.DUCTDELTA_CHROME ?? '/usr/bin/google-chrome' })
const owner = process.argv[2] === 'create'
const page = await browser.newPage({
  viewport: owner ? { width: 1440, height: 1000 } : { width: 390, height: 844 },
  isMobile: !owner,
  hasTouch: !owner
})
page.setDefaultTimeout(12000)
const errors = []
page.on('pageerror', error => errors.push(error.message))
const button = name => page.getByRole('button', { name, exact: true })
const heading = name => page.getByRole('heading', { name, exact: true })

try {
  await page.goto(owner ? process.env.DD_INVITE_ORIGIN : process.env.DD_INVITE_LINK)
  if (owner) {
    await button('Create a company').click()
    await page.getByLabel('Company name').fill('Mechanical Works')
    await page.getByLabel('Your name').fill('Company lead')
    await page.getByLabel('Company setup code').fill('wrong')
    await button('Create company').click()
    await page.getByRole('alert').getByText('Enter the company setup code from your deployment administrator.').waitFor()
    await page.getByLabel('Company setup code').fill(process.env.DD_COMPANY_SETUP_CODE)
    await button('Create company').click()
    await heading('Save your sign-in keys').waitFor()
    await button('I saved my keys').click()
    await heading('Invitations').waitFor()
    await page.getByLabel('Invitee name').fill('Site lead')
    await page.getByLabel('Invitee email').fill('site@example.test')
    await button('Send invitation email').click()
    await page.getByText('Email accepted by provider', { exact: true }).waitFor()
    assert.equal(await page.getByText(/email queued/i).count(), 0)
    assert.equal(await page.getByLabel('Invitation link').count(), 0)
    console.log('PASS: Chrome queues email in company settings and shows provider acceptance')
  } else {
    await heading('Join the company').waitFor()
    await page.waitForFunction(() => !location.hash)
    await button('Accept invitation').click()
    await heading('Save your sign-in keys').waitFor()
    await button('I saved my keys').click()
    await page.getByText('Your account has no assigned projects.', { exact: true }).waitFor()
    console.log('PASS: phone Chrome opens the actual queued email link and joins the company')
  }
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
  assert.deepEqual(errors, [])
  const viewport = owner ? 'desktop' : 'phone'
  await page.screenshot({ path: 'artifacts/email-invitation-' + viewport + '.png', animations: 'disabled' })
} finally {
  await browser.close()
}
