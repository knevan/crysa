<script setup lang="ts">
import { ref, computed } from 'vue'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/assets/vue/components/ui/card'
import { Button } from '@/assets/vue/components/ui/button'
import { Input } from '@/assets/vue/components/ui/input'
import { Label } from '@/assets/vue/components/ui/label'
import { cn } from '@/assets/vue/lib/utils'

defineProps<{
  action: string
  csrfToken: string
}>()

const email = ref('')
const emailTouched = ref(false)

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
</script>

<template>
  <div class="flex min-h-[calc(100vh-12rem)] items-center justify-center py-8 px-4">
    <div class="w-full max-w-md space-y-6">
      <Card>
        <CardHeader class="space-y-1 text-center">
          <CardTitle class="text-2xl font-semibold tracking-tight">Reset your password</CardTitle>
          <CardDescription> Enter your Gmail and we'll send you a reset link. </CardDescription>
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

            <Button type="submit" variant="outline" class="w-full bg-white hover:bg-zinc-50 text-zinc-900 border-zinc-200 shadow-sm dark:bg-zinc-900 dark:hover:bg-zinc-800 dark:text-white dark:border-zinc-800">Send reset instructions</Button>
          </form>

          <div class="mt-6 text-center text-sm">
            Back to <a href="/auth/login" class="underline underline-offset-4 font-medium hover:text-primary">Log in</a>
          </div>
        </CardContent>
      </Card>
    </div>
  </div>
</template>
