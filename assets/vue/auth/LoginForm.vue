<script setup lang="ts">
import { ref } from 'vue'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/assets/vue/components/ui/card'
import { Button } from '@/assets/vue/components/ui/button'
import { Input } from '@/assets/vue/components/ui/input'
import { Label } from '@/assets/vue/components/ui/label'
import { Eye, EyeOff } from '@lucide/vue'
import { cn } from '@/assets/vue/lib/utils'

const props = defineProps<{
  action: string
  csrfToken: string
  login?: string | null
  error?: string | null
}>()

const loginValue = ref(props.login ?? '')
const showPassword = ref(false)
</script>

<template>
  <div class="flex min-h-[calc(100vh-12rem)] items-center justify-center py-8 px-4">
    <div class="w-full max-w-md space-y-6">
      <Card class="border shadow-sm">
        <CardHeader class="space-y-1 text-center">
          <CardTitle class="text-2xl font-semibold tracking-tight">Login</CardTitle>
          <CardDescription class="text-sm text-muted-foreground">
            Enter your email or username below to login to your account
          </CardDescription>
        </CardHeader>
        <CardContent>
          <!-- Native POST to UserSessionController — keeps HttpOnly Secure SameSite cookie flow -->
          <form :action="action" method="post" class="space-y-4">
            <input type="hidden" name="_csrf_token" :value="csrfToken" />

            <div class="space-y-2">
              <Label for="user_login">Credential</Label>
              <Input
                id="user_login"
                name="user[login]"
                v-model="loginValue"
                autocomplete="username"
                placeholder="ex@gmail.com or username"
                required
                :aria-invalid="!!error"
                :class="cn(error && 'border-destructive focus-visible:ring-destructive/20 focus-visible:border-destructive')"
              />
            </div>

            <div class="space-y-2">
              <div class="flex items-center justify-between">
                <Label for="user_password">Password</Label>
                <a href="/auth/reset-password" class="text-sm underline underline-offset-4 hover:text-primary">
                  Forgot your password?
                </a>
              </div>
              <div class="relative">
                <Input
                  id="user_password"
                  name="user[password]"
                  :type="showPassword ? 'text' : 'password'"
                  autocomplete="current-password"
                  required
                  class="pr-10"
                  :aria-invalid="!!error"
                  :class="cn(error && 'border-destructive focus-visible:ring-destructive/20 focus-visible:border-destructive')"
                />
                <button
                  type="button"
                  @click="showPassword = !showPassword"
                  class="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground transition-colors"
                  tabindex="-1"
                  :aria-label="showPassword ? 'Hide password' : 'Show password'"
                >
                  <EyeOff v-if="showPassword" class="h-4 w-4" />
                  <Eye v-else class="h-4 w-4" />
                </button>
              </div>
            </div>

            <!-- Inline invalid credential — di bawah password, di atas tombol (lebih dekat ke CTA) -->
            <p
              v-if="error"
              class="text-sm text-destructive text-center bg-destructive/10 border border-destructive/20 rounded-md px-3 py-2 animate-in fade-in slide-in-from-top-1 duration-200"
              role="alert"
            >
              {{ error }}
            </p>

            <Button type="submit" variant="outline" class="w-full bg-white hover:bg-zinc-50 text-zinc-900 border-zinc-200 shadow-sm dark:bg-zinc-900 dark:hover:bg-zinc-800 dark:text-white dark:border-zinc-800">Login</Button>
          </form>

          <div class="mt-6 text-center text-sm">
            Don't have an account?
            <a href="/auth/register" class="underline underline-offset-4 font-medium hover:text-primary">Sign up</a>
          </div>
        </CardContent>
      </Card>
    </div>
  </div>
</template>
