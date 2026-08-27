<script setup lang="ts">
import { ref, computed } from 'vue'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/assets/vue/components/ui/card'
import { Button } from '@/assets/vue/components/ui/button'
import { Input } from '@/assets/vue/components/ui/input'
import { Label } from '@/assets/vue/components/ui/label'
import { cn } from '@/assets/vue/lib/utils'

const props = defineProps<{
  action: string
  csrfToken: string
  email?: string | null
  username?: string | null
}>()

const email = ref(props.email ?? '')
const username = ref(props.username ?? '')
const password = ref('')
const passwordConfirmation = ref('')

const emailTouched = ref(false)
const usernameTouched = ref(false)
const passwordTouched = ref(false)
const confirmTouched = ref(false)

// Gmail-only for now — add 'proton.me' / 'protonmail.com' later
const ALLOWED_EMAIL_DOMAINS = ['gmail.com']

const emailError = computed<string | null>(() => {
  if (!emailTouched.value) return null
  const v = email.value.trim()
  if (v.length === 0) return 'Email is required.'
  if (!/^[^\s]+@[^\s]+$/.test(v)) return 'Invalid email format.'
  const domain = v.split('@')[1]?.toLowerCase()
  if (!ALLOWED_EMAIL_DOMAINS.includes(domain)) return 'Only Gmail addresses are allowed (e.g., you@gmail.com).'
  return null
})

const isEmailValid = computed(() => emailTouched.value && email.value.trim().length > 0 && !emailError.value)

// Username: 3-40 chars, letters+numbers only [a-zA-Z0-9]
const usernameError = computed<string | null>(() => {
  if (!usernameTouched.value) return null
  const v = username.value.trim()
  if (v.length === 0) return 'Username is required.'
  if (v.length < 3) return 'Username must be at least 3 characters.'
  if (v.length > 40) return 'Username must be at most 40 characters.'
  if (!/^[a-zA-Z0-9]+$/.test(v)) return 'Username may only contain letters and numbers (no symbols, spaces, or -+).'
  return null
})

const isUsernameValid = computed(() => usernameTouched.value && username.value.trim().length > 0 && !usernameError.value)

// Password: 8-72 chars, at least one lowercase
const passwordError = computed<string | null>(() => {
  if (!passwordTouched.value) return null
  const v = password.value
  if (v.length === 0) return 'Password is required.'
  if (v.length < 8) return 'Password must be at least 8 characters.'
  if (v.length > 72) return 'Password must be at most 72 characters.'
  if (!/[a-z]/.test(v)) return 'Password must contain at least one lowercase letter.'
  return null
})

const isPasswordValid = computed(() => passwordTouched.value && password.value.length > 0 && !passwordError.value)

const confirmError = computed<string | null>(() => {
  if (!confirmTouched.value) return null
  if (passwordConfirmation.value.length === 0) return 'Please confirm your password.'
  if (passwordConfirmation.value !== password.value) return 'Passwords do not match.'
  return null
})

const isConfirmValid = computed(
  () => confirmTouched.value && passwordConfirmation.value.length > 0 && !confirmError.value
)
</script>

<template>
  <div class="flex min-h-[calc(100vh-12rem)] items-center justify-center py-8 px-4">
    <div class="w-full max-w-md space-y-6">
      <Card>
        <CardHeader class="space-y-1 text-center">
          <CardTitle class="text-2xl font-semibold tracking-tight">Create your account</CardTitle>
          <CardDescription>
            Already have an account?
            <a href="/auth/login" class="font-semibold text-primary underline underline-offset-4 hover:text-primary/80">Log in</a>
          </CardDescription>
        </CardHeader>
        <CardContent>
          <form :action="action" method="post" class="space-y-4">
            <input type="hidden" name="_csrf_token" :value="csrfToken" />

            <div class="space-y-1.5">
              <Label for="user_email">Email</Label>
              <Input
                id="user_email"
                name="user[email]"
                type="email"
                v-model="email"
                autocomplete="email"
                placeholder="you@gmail.com"
                required
                :aria-invalid="!!emailError"
                :class="
                  cn(
                    emailTouched && emailError && 'border-destructive focus-visible:ring-destructive/20',
                    emailTouched && isEmailValid && 'border-green-500 focus-visible:ring-green-500/20 focus-visible:border-green-500'
                  )
                "
                @update:modelValue="emailTouched = true"
              />
              <p v-if="emailError" class="text-xs text-destructive animate-in fade-in slide-in-from-top-1 duration-200">
                {{ emailError }}
              </p>
              <p v-else-if="isEmailValid" class="text-xs text-green-600 animate-in fade-in slide-in-from-top-1 duration-200">
                Gmail looks good ✓
              </p>
            </div>

            <div class="space-y-1.5">
              <Label for="user_username">Username</Label>
              <Input
                id="user_username"
                name="user[username]"
                v-model="username"
                autocomplete="username"
                placeholder="username"
                required
                :aria-invalid="!!usernameError"
                :class="
                  cn(
                    usernameTouched && usernameError && 'border-destructive focus-visible:ring-destructive/20',
                    usernameTouched && isUsernameValid && 'border-green-500 focus-visible:ring-green-500/20 focus-visible:border-green-500'
                  )
                "
                @update:modelValue="usernameTouched = true"
              />
              <p v-if="usernameError" class="text-xs text-destructive animate-in fade-in slide-in-from-top-1 duration-200">
                {{ usernameError }}
              </p>
              <p v-else-if="isUsernameValid" class="text-xs text-green-600 animate-in fade-in slide-in-from-top-1 duration-200">
                Username looks good ✓
              </p>
            </div>

            <div class="space-y-1.5">
              <Label for="user_password">Password</Label>
              <Input
                id="user_password"
                name="user[password]"
                type="password"
                v-model="password"
                autocomplete="new-password"
                required
                :aria-invalid="!!passwordError"
                :class="
                  cn(
                    passwordTouched && passwordError && 'border-destructive focus-visible:ring-destructive/20',
                    passwordTouched && isPasswordValid && 'border-green-500 focus-visible:ring-green-500/20 focus-visible:border-green-500'
                  )
                "
                @update:modelValue="passwordTouched = true"
              />
              <p v-if="passwordError" class="text-xs text-destructive animate-in fade-in slide-in-from-top-1 duration-200">
                {{ passwordError }}
              </p>
              <p v-else-if="isPasswordValid" class="text-xs text-green-600 animate-in fade-in slide-in-from-top-1 duration-200">
                Password looks good ✓
              </p>
            </div>

            <div class="space-y-1.5">
              <Label for="user_password_confirmation">Confirm password</Label>
              <Input
                id="user_password_confirmation"
                name="user[password_confirmation]"
                type="password"
                v-model="passwordConfirmation"
                autocomplete="new-password"
                required
                :aria-invalid="!!confirmError"
                :class="
                  cn(
                    confirmTouched && confirmError && 'border-destructive focus-visible:ring-destructive/20',
                    confirmTouched && isConfirmValid && 'border-green-500 focus-visible:ring-green-500/20 focus-visible:border-green-500'
                  )
                "
                @update:modelValue="confirmTouched = true"
              />
              <p v-if="confirmError" class="text-xs text-destructive animate-in fade-in slide-in-from-top-1 duration-200">
                {{ confirmError }}
              </p>
              <p v-else-if="isConfirmValid" class="text-xs text-green-600 animate-in fade-in slide-in-from-top-1 duration-200">
                Passwords match ✓
              </p>
            </div>

            <Button type="submit" variant="outline" class="w-full bg-white hover:bg-zinc-50 text-zinc-900 border-zinc-200 shadow-sm dark:bg-zinc-900 dark:hover:bg-zinc-800 dark:text-white dark:border-zinc-800">Create account</Button>
          </form>
        </CardContent>
      </Card>
    </div>
  </div>
</template>
