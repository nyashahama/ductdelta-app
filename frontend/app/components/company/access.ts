export type CompanyProject = { id: string, name: string }
export type Member = { id: string, name: string, role: 'admin' | 'member' }
export type Capability = 'direction' | 'commercial' | 'finance'
export type Access = {
  project_id: string
  actor_id: string
  permission: 'read' | 'capture'
  capabilities: Capability[]
}
export type Team = {
  actor_id: string
  members: Member[]
  access: Access[]
  invitations: { id: string, name: string, expires_at: string }[]
}
export type EmailInvitation = {
  id: string
  email: string
  state: 'queued' | 'accepted' | 'needs_attention'
}
export type InvitationDelivery = { email_enabled: boolean, deliveries: EmailInvitation[] }
