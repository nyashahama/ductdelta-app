const token = new URLSearchParams(location.hash.slice(1)).get('key')
if (location.hash) history.replaceState(null, '', location.pathname)

const download = document.getElementById('download')
const status = document.getElementById('status')

if (/^[a-f0-9]{64}$/i.test(token ?? '')) {
  download.hidden = false
  status.textContent = 'Download the text file to keep an exact copy of this version.'
  download.addEventListener('click', async () => {
    download.disabled = true
    try {
      const response = await fetch('/api/notice-copy', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        credentials: 'omit',
        referrerPolicy: 'no-referrer',
        body: JSON.stringify({ token })
      })
      if (response.status === 404) {
        status.textContent = 'This recipient link is unavailable. Ask the sender for a current link.'
        download.hidden = true
        return
      }
      if (!response.ok) throw new Error('Download request failed')
      const url = URL.createObjectURL(await response.blob())
      const link = document.createElement('a')
      link.href = url
      link.download = /filename="(notice-version-\d+\.txt)"/.exec(response.headers.get('Content-Disposition'))?.[1]
        ?? 'issued-notice.txt'
      link.click()
      setTimeout(() => URL.revokeObjectURL(url), 10000)
      status.textContent = 'Your download is ready.'
    } catch {
      status.textContent = 'The download failed. Try again.'
    } finally {
      download.disabled = false
    }
  })
}
