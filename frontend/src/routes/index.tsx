import { createFileRoute } from '@tanstack/react-router'
import { Workspace, type WorkspaceSearch } from '../workspace'

function validateSearch(input: Record<string, unknown>): WorkspaceSearch {
  const id = (value: unknown) => typeof value === 'string' && /^[a-f0-9-]{36}$/i.test(value)
    ? value : undefined
  const view = input.view === 'observations' || input.view === 'cases' ? input.view : undefined
  return {
    project: id(input.project),
    view,
    caseId: view === 'cases' ? id(input.caseId) : undefined,
    observationId: view === 'observations' ? id(input.observationId) : undefined,
  }
}

export const Route = createFileRoute('/')({
  validateSearch,
  component: App,
})

function App() {
  const search = Route.useSearch()
  const navigate = Route.useNavigate()
  return <Workspace search={search} navigate={(search) => void navigate({ search })} />
}
