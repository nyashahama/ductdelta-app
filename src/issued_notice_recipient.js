const download = document.getElementById('download')
const status = document.getElementById('status')
let token = null

function openLink() {
  const key = new URLSearchParams(location.hash.slice(1)).get('key')
  if (location.hash) history.replaceState(null, '', location.pathname)
  token = /^[a-f0-9]{64}$/i.test(key ?? '') ? key : null
  download.hidden = token === null
  download.disabled = false
  status.textContent = token
    ? 'Download the text file to keep an exact copy of this version.'
    : 'Open the recipient link provided by the sender.'
}

openLink()
window.addEventListener('hashchange', openLink)

download.addEventListener('click', async () => {
  const selected = token
  if (!selected) return
  download.disabled = true
  try {
    const response = await fetch('/api/notice-copy', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      credentials: 'omit',
      referrerPolicy: 'no-referrer',
      body: JSON.stringify({ token: selected })
    })
    if (token !== selected) return
    if (response.status === 404) {
      status.textContent = 'This recipient link is unavailable. Ask the sender for a current link.'
      download.hidden = true
      return
    }
    if (!response.ok) throw new Error('Download request failed')
    const file = await response.blob()
    if (token !== selected) return
    const url = URL.createObjectURL(file)
    const link = document.createElement('a')
    link.href = url
    link.download = /filename="(notice-version-\d+\.txt)"/.exec(response.headers.get('Content-Disposition'))?.[1]
      ?? 'issued-notice.txt'
    link.click()
    setTimeout(() => URL.revokeObjectURL(url), 10000)
    status.textContent = 'Your download is ready.'
  } catch {
    if (token === selected) status.textContent = 'The download failed. Try again.'
  } finally {
    if (token === selected) download.disabled = false
  }
})
