// Shared prop types for the UserSettings island.
//
// The LiveView is the source of truth: it projects only safe scalar values
// (never raw Ecto forms — a User changeset would leak `password_hash` through
// LiveVue's form encoder, and password values must never flow server → client).

export type AccountState = {
  email: string
  displayName: string
  emailErrors: string[]
  displayNameErrors: string[]
}

export type PasswordErrors = {
  currentPassword: string[]
  password: string[]
  passwordConfirmation: string[]
}

export type PasswordState = {
  errors: PasswordErrors
}

export function emptyPasswordErrors(): PasswordErrors {
  return { currentPassword: [], password: [], passwordConfirmation: [] }
}
