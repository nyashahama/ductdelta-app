import { HeadContent, Outlet, Scripts, createRootRoute } from '@tanstack/react-router'
import styles from '../workspace.css?url'

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: 'utf-8' },
      { name: 'viewport', content: 'width=device-width, initial-scale=1' },
      { name: 'color-scheme', content: 'dark' },
      { title: 'DuctDelta Workspace' },
    ],
    links: [{ rel: 'stylesheet', href: styles }],
  }),
  component: Outlet,
  pendingComponent: () => <p className="startup" role="status">Opening DuctDelta…</p>,
  shellComponent: ({ children }) => (
    <html lang="en">
      <head><HeadContent /><Scripts /></head>
      <body>{children}</body>
    </html>
  ),
})
