<script setup lang="ts">
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/assets/vue/components/ui/card'
import { Button } from '@/assets/vue/components/ui/button'
import { Input } from '@/assets/vue/components/ui/input'
import { Label } from '@/assets/vue/components/ui/label'

// Props from LiveView — server is source of truth
// action and csrfToken are required for native POST (session cookie must be set via HTTP response)
defineProps<{
  action: string
  csrfToken: string
  login?: string | null
}>()
</script>

<template>
  <div class="mx-auto max-w-md space-y-6">
    <Card>
      <CardHeader class="space-y-1 text-center">
        <CardTitle class="text-2xl font-semibold tracking-tight">Log in</CardTitle>
        <CardDescription>
          Don't have an account?
          <a href="/users/register" class="font-semibold text-primary hover:underline">Sign up</a>
          for an account now.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <!-- Native POST to UserSessionController — keeps HttpOnly Secure SameSite cookie flow -->
        <form :action="action" method="post" class="space-y-4">
          <input type="hidden" name="_csrf_token" :value="csrfToken" />

          <div class="space-y-2">
            <Label for="user_login">Email or username</Label>
            <Input
              id="user_login"
              name="user[login]"
              :default-value="login ?? ''"
              autocomplete="username"
              placeholder="you@example.com or username"
              required
            />
          </div>

          <div class="space-y-2">
            <Label for="user_password">Password</Label>
            <Input
              id="user_password"
              name="user[password]"
              type="password"
              autocomplete="current-password"
              required
            />
          </div>

          <div class="flex items-center justify-between text-sm">
            <a href="/users/reset_password" class="text-primary hover:underline underline-offset-4">
              Forgot your password?
            </a>
          </div>

          <Button type="submit" class="w-full">Log in</Button>
        </form>
      </CardContent>
    </Card>
  </div>
</template>
