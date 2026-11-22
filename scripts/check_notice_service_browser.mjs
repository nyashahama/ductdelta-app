import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'

const { chromium } = await import(pathToFileURL(process.env.DUCTDELTA_PLAYWRIGHT_MODULE).href)
const { DD_SERVICE_ORIGIN: origin, DD_SERVICE_PROJECT: project, DD_SERVICE_ADMIN: admin, DD_SERVICE_VIEWER: viewer } = process.env
const configured = process.env.DD_SERVICE_CONFIGURED === '1'
const browser = await chromium.launch({ executablePath: process.env.DUCTDELTA_CHROME ?? '/usr/bin/google-chrome' })
const errors = []
const actionSection = page => page.getByRole('region', { name: 'Record an action', exact: true })
const form = (page, name) => actionSection(page).getByRole('form', { name, exact: true })
const button = (scope, name) => scope.getByRole('button', { name, exact: true })
const field = (scope, name) => scope.getByLabel(name, { exact: true })
const digest = bytes => createHash('sha256').update(bytes).digest('hex')
const route = origin + '/api/projects/' + project + '/cases'

async function select(page, scope, name, value) {
  await scope.getByRole('combobox', { name, exact: true }).click()
  await page.getByRole('option', { name: value, exact: true }).click()
}

async function signIn(context, key) {
  const page = await context.newPage()
  page.setDefaultTimeout(10000)
  page.on('pageerror', error => errors.push(error.message))
  await page.goto(origin + '/?project=' + project)
  await field(page, 'Access key').fill(key)
  await button(page, 'Sign in').click()
  await page.getByRole('heading', { name: 'Project overview', exact: true }).waitFor()
  return page
}

async function download(page, trigger) {
  const next = page.waitForEvent('download')
  await trigger.click()
  const result = await next
  return readFile(await result.path())
}

try {
  const office = await browser.newContext({ viewport: { width: 1440, height: 1000 } })
  const staff = await signIn(office, admin)
  if (configured) {
    await staff.getByRole('link', { name: 'Notice rules', exact: true }).click()
    const rule = staff.getByRole('form', { name: 'Publish notice rule' })
    await field(rule, 'Agreement reference').fill('MECH-02')
    await field(rule, 'Clause').fill('12.4')
    await field(rule, 'Issuing authority').fill('Contract manager')
    await select(staff, rule, 'Authorized issuer', 'Site administrator')
    await field(rule, 'Recipient').fill('Engineer of record')
    await field(rule, 'Service method').fill('Contract portal')
    await field(rule, 'Contract time zone').fill('Africa/Johannesburg')
    await field(rule, 'Trigger event').fill('Discovery of change')
    await select(staff, rule, 'Deadline mechanism', 'Calendar days')
    await rule.getByRole('spinbutton', { name: 'Calendar days', exact: true }).fill('1')
    await button(rule, 'Publish rule').click()
    await staff.getByText('Rule version 1 published.', { exact: true }).waitFor()
  }

  const create = await staff.request.post(route, {
    headers: { Origin: origin },
    data: { operation_id: crypto.randomUUID(), title: 'Duct adjustment at beam' }
  })
  assert.equal(create.status(), 200)
  const { id } = await create.json()
  const caseUrl = origin + '/?project=' + project + '&view=cases&caseId=' + id
  const caseApi = route + '/' + id
  await staff.goto(caseUrl)
  await select(staff, actionSection(staff), 'Action', 'Record notice')
  const notice = form(staff, 'Record notice')
  await field(notice, 'Notice reference').fill('N-001')
  await field(notice, 'Notice text').fill('Private draft. Review the configuration first.')
  if (configured) {
    await field(notice, 'Trigger date, time and offset').fill('2026-04-10T17:00:00+02:00')
  } else {
    await field(notice, 'Agreement reference').fill('MECH-02')
  }
  await button(notice, 'Record action').click()
  await staff.getByText('Action recorded.', { exact: true }).waitFor()

  const copies = staff.getByRole('region', { name: 'Issued notice copies', exact: true })
  await button(copies, 'Issue a copy').click()
  if (configured) {
    assert.equal(await field(copies, 'Recipient').inputValue(), 'Engineer of record')
    assert.equal(await field(copies, 'Recipient').getAttribute('readonly'), '')
  } else {
    await field(copies, 'Recipient').fill('Engineer of record')
  }
  await field(copies, 'Recipient-facing text').fill('Version 1 advises a revised duct route.')
  await button(copies, 'Issue version 1').click()
  const first = await download(staff, copies.getByRole('link', { name: 'Download version 1', exact: true }))
  await button(copies, 'Issue a new version').click()
  await field(copies, 'Recipient-facing text').fill('Version 2 supplies the corrected route.')
  await button(copies, 'Issue version 2').click()
  const second = await download(staff, copies.getByRole('link', { name: 'Download version 2', exact: true }))
  assert.notDeepEqual(first, second)

  async function dispatch(version, reference, correction) {
    await select(staff, actionSection(staff), 'Action', 'Record notice dispatch')
    const scope = form(staff, 'Record notice dispatch')
    await select(staff, scope, 'Notice', 'Notice N-001')
    await select(staff, scope, 'Issued copy', 'Version ' + version + ' · Engineer of record')
    if (configured) {
      assert.equal(await field(scope, 'Actual service method').inputValue(), 'Contract portal')
      if (correction) {
        await field(scope, 'Actual service method').fill('Agreed project email')
        await field(scope, 'Service exception evidence').fill('Written authorization in portal record 48.')
      }
    } else {
      await field(scope, 'Actual service method').fill('Contract portal')
    }
    await scope.getByRole('checkbox', { name: 'Confirm this version was sent to the recipient shown' }).check()
    if (correction) await select(staff, scope, 'Corrects earlier dispatch', 'Notice dispatched ' + correction + ' · version 1')
    await field(scope, 'Dispatch reference').fill(reference)
    await button(scope, 'Record action').click()
    await staff.getByText('Notice dispatched ' + reference, { exact: true }).waitFor()
  }
  await dispatch(1, 'Portal A')
  await copies.getByText('Latest version has no dispatch record', { exact: true }).waitFor()
  await dispatch(2, 'Portal B', 'Portal A')
  await copies.getByText('Latest version has no dispatch record', { exact: true }).waitFor({ state: 'hidden' })
  const before = await (await staff.request.get(caseApi)).json()
  assert.equal(before.events.filter(event => event.kind === 'notice_receipt').length, 0)
  assert.deepEqual(before.events.filter(event => event.kind === 'notice_dispatch').map(event => event.data.copy.sha256),
    [digest(first), digest(second)])

  await select(staff, actionSection(staff), 'Action', 'Record notice acknowledgement')
  const ack = form(staff, 'Record notice acknowledgement')
  await select(staff, ack, 'Dispatch', 'Notice dispatched Portal B · version 2')
  await field(ack, 'Acknowledgement reference').fill('Received B')
  await button(ack, 'Record action').click()
  await staff.getByText('Notice acknowledged Received B', { exact: true }).click()
  const after = await (await staff.request.get(caseApi)).json()
  const acknowledgement = after.events.find(event => event.kind === 'notice_receipt')
  const secondDispatch = after.events.find(event => event.data.reference === 'Portal B')
  assert.equal(acknowledgement.data.dispatch, secondDispatch.id)
  assert.equal(acknowledgement.data.copy.version, 2)
  assert.deepEqual(acknowledgement.data.copy, secondDispatch.data.copy)
  if (configured) {
    assert.equal(secondDispatch.data.service_method, 'Agreed project email')
    assert.equal(secondDispatch.data.service_evidence, 'Written authorization in portal record 48.')
    const incomplete = await staff.request.post(caseApi + '/actions', {
      headers: { Origin: origin },
      data: { operation_id: crypto.randomUUID(), kind: 'notice_dispatch', data: {
        notice: secondDispatch.data.notice, issued_copy: secondDispatch.data.copy.id,
        recipient: secondDispatch.data.copy.recipient, reference: 'No basis for alternate method',
        service_method: 'Unspecified alternative'
      } }
    })
    assert.equal(incomplete.status(), 422)
  }
  await staff.getByText('Notice dispatched Portal B', { exact: true }).last().waitFor()
  await staff.getByText(digest(second), { exact: true }).last().waitFor()
  const evidence = staff.getByRole('region', { name: 'Evidence timeline', exact: true })
  assert.deepEqual(await download(staff, evidence.getByRole('link', { name: 'Download issued version 2' })), second)
  await staff.screenshot({ path: 'artifacts/notice-service-desktop.png' })

  const phone = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true })
  const recipient = await phone.newPage()
  let firstLink
  for (const [version, expected] of [[1, first], [2, second]]) {
    await button(copies, 'Create recipient link for version ' + version).click()
    const link = await field(copies, 'Recipient link for version ' + version).inputValue()
    if (version === 1) firstLink = link
    await recipient.goto(link)
    await recipient.waitForFunction(() => !location.hash)
    assert.deepEqual(await download(recipient, button(recipient, 'Download issued copy')), expected)
  }
  assert.ok(await recipient.evaluate(() => document.documentElement.scrollWidth <= innerWidth))
  await recipient.screenshot({ path: 'artifacts/notice-service-recipient-mobile.png' })
  await button(copies, 'Revoke recipient link for version 1').click()
  await copies.getByText('Recipient link revoked', { exact: true }).waitFor()
  await recipient.goto(firstLink)
  await button(recipient, 'Download issued copy').click()
  await recipient.getByText('This recipient link is unavailable.', { exact: false }).waitFor()
  assert.equal((await recipient.request.get(caseApi)).status(), 401)
  assert.deepEqual((await (await staff.request.get(caseApi)).json()).events, after.events)
  const readOnly = await browser.newContext()
  const projectViewer = await signIn(readOnly, viewer)
  const forbidden = await projectViewer.request.post(caseApi + '/actions', {
    headers: { Origin: origin },
    data: { operation_id: crypto.randomUUID(), kind: 'notice_dispatch', data: { notice: before.events[0].id, reference: 'Unauthorized' } }
  })
  assert.equal(forbidden.status(), 404)
  assert.deepEqual(errors, [])
  console.log('PASS: Chrome notice service, versioned dispatch and acknowledgement, exact anonymous downloads and revocation' +
    (configured ? ' with a rule published in the UI' : ''))
} finally {
  await browser.close()
}
