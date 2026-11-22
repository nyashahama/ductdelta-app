import assert from 'node:assert/strict'
import { pathToFileURL } from 'node:url'

const { chromium } = await import(pathToFileURL(process.env.DUCTDELTA_PLAYWRIGHT_MODULE).href)
const { DD_RULE_ORIGIN: origin, DD_RULE_PROJECT: project, DD_RULE_ADMIN: adminKey, DD_RULE_VIEWER: viewerKey } = process.env
const settings = `${origin}/api/projects/${project}/notice-rule`
const browser = await chromium.launch({ executablePath: process.env.DUCTDELTA_CHROME ?? '/usr/bin/google-chrome' })
const errors = []
const button = (page, name) => page.getByRole('button', { name, exact: true })
const heading = (page, name) => page.getByRole('heading', { name, exact: true })
const label = (page, name) => page.getByLabel(name, { exact: true })
const withinViewport = page => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)

async function openProject(context, key) {
  const page = await context.newPage()
  page.on('pageerror', error => errors.push(error.message))
  page.setDefaultTimeout(10000)
  await page.goto(origin + '/?project=' + project)
  await heading(page, 'Sign in to your workspace').waitFor()
  await label(page, 'Access key').fill(key)
  await button(page, 'Sign in').click()
  await heading(page, 'Project overview').waitFor()
  return page
}

try {
  const desktop = await browser.newContext({ viewport: { width: 1440, height: 900 } })
  const owner = await openProject(desktop, adminKey)
  await owner.getByRole('link', { name: 'Notice rules', exact: true }).click()
  const setup = owner.getByRole('form', { name: 'Publish notice rule' })
  await setup.getByLabel('Agreement reference', { exact: true }).fill('MECH-02')
  await label(owner, 'Clause').fill('12.3')
  await label(owner, 'Issuing authority').fill('Contract manager')
  await owner.getByRole('combobox', { name: 'Authorized issuer', exact: true }).click()
  await owner.getByRole('option', { name: 'Site administrator', exact: true }).click()
  await label(owner, 'Recipient').fill('Engineer of record')
  await label(owner, 'Service method').fill('Contract portal')
  await label(owner, 'Contract time zone').fill('Africa/Johannesburg')
  await label(owner, 'Trigger event').fill('Discovery of change')
  await owner.getByRole('combobox', { name: 'Deadline mechanism', exact: true }).click()
  await owner.getByRole('option', { name: 'Calendar days', exact: true }).click()
  await owner.getByRole('spinbutton', { name: 'Calendar days', exact: true }).fill('1')
  await button(owner, 'Publish rule').click()
  await owner.getByText('Rule version 1 published.', { exact: true }).waitFor()
  assert.equal((await (await owner.request.get(settings)).json()).rule.authority, 'Contract manager')
  assert.ok(await withinViewport(owner))
  await owner.screenshot({ path: 'artifacts/notice-rules-desktop.png' })

  const cases = origin + '/api/projects/' + project + '/cases'
  const created = await owner.request.post(cases, {
    headers: { Origin: origin },
    data: { operation_id: crypto.randomUUID(), title: 'Plantroom offset' },
  })
  assert.equal(created.status(), 200)
  const { id } = await created.json()
  const caseUrl = origin + '/?project=' + project + '&view=cases&caseId=' + id
  const mobile = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true })
  const field = await openProject(mobile, adminKey)
  await field.goto(caseUrl)
  await field.getByRole('combobox', { name: 'Action', exact: true }).click()
  await field.getByRole('option', { name: 'Record notice', exact: true }).click()
  const action = field.getByRole('form', { name: 'Record notice' })
  await action.getByText('Discovery of change', { exact: true }).waitFor()
  await action.getByText('Site administrator · Contract manager', { exact: true }).waitFor()
  await action.getByLabel('Notice reference').fill('N-001')
  await action.getByLabel('Notice text').fill('Offset the duct to clear the beam.')
  await action.getByLabel('Trigger date, time and offset').fill('2026-04-10T17:00:00+02:00')
  assert.ok(await withinViewport(field))
  await field.screenshot({ path: 'artifacts/notice-entry-mobile.png' })
  const { rule: lastRule } = await (await owner.request.get(settings)).json()
  const { version, issuer_name, ...rule } = lastRule
  assert.equal(issuer_name, 'Site administrator')
  assert.equal((await owner.request.post(settings, {
    headers: { Origin: origin },
    data: { operation_id: crypto.randomUUID(), expected_version: version, rule: { ...rule, clause: '12.4' } }
  })).status(), 200)
  await button(field, 'Record action').click()
  await action.getByRole('alert').getByText('The notice rule changed.', { exact: false }).waitFor()
  await button(field, 'Refresh notice rule').click()
  await action.getByText('MECH-02 · 12.4', { exact: true }).waitFor()
  assert.equal(await action.getByLabel('Notice text').inputValue(), 'Offset the duct to clear the beam.')

  const saveUrl = cases + '/' + id + '/actions'
  let firstOperation
  await field.route(saveUrl, async (route) => {
    firstOperation = route.request().postDataJSON().operation_id
    const recorded = await route.fetch()
    assert.equal(recorded.status(), 200)
    await route.abort()
  }, { times: 1 })
  await button(field, 'Record action').click()
  await action.getByText('Could not reach DuctDelta. Try again.', { exact: true }).waitFor()
  const retry = field.waitForRequest(request => request.url() === saveUrl && request.method() === 'POST')
  await button(field, 'Record action').click()
  assert.equal((await retry).postDataJSON().operation_id, firstOperation)
  await field.getByText('Notice N-001', { exact: true }).click()
  assert.equal(await field.getByText('Notice N-001', { exact: true }).count(), 1)
  await field.getByText('Engineer of record', { exact: true }).waitFor()
  await field.getByText('Contract portal', { exact: true }).waitFor()
  await field.getByText('2026-04-11 21:59:59.999999 UTC', { exact: true }).waitFor()

  const readOnly = await browser.newContext()
  const viewer = await openProject(readOnly, viewerKey)
  await viewer.goto(origin + '/?project=' + project + '&view=notice-rules')
  await viewer.getByText('Contract manager', { exact: false }).first().waitFor()
  assert.equal(await button(viewer, 'Publish rule').count(), 0)
  await viewer.goto(caseUrl)
  await viewer.getByRole('combobox', { name: 'Action', exact: true }).click()
  await viewer.getByRole('option', { name: 'Record notice', exact: true }).click()
  await viewer.getByText('Only the configured issuer can record this notice.', { exact: true }).waitFor()
  assert.equal(await button(viewer, 'Record action').count(), 0)
  assert.deepEqual(errors, [])
  console.log('PASS: Chromium desktop setup, mobile entry, stale rules, lost response retry, saved deadline and issuer controls')
} finally {
  await browser.close()
}
