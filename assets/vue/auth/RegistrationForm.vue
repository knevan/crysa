<script setup lang="ts">
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/assets/vue/components/ui/card'
import { Button } from '@/assets/vue/components/ui/button'
import { Input } from '@/assets/vue/components/ui/input'
import { Label } from '@/assets/vue/components/ui/label'

defineProps<{
  action: string
  csrfToken: string
  email?: string | null
  username?: string | null
}>()
</script>

<template>
  <div class="mx-auto max-w-md space-y-6">
    <Card>
      <CardHeader class="space-y-1 text-center">
        <CardTitle class="text-2xl font-semibold tracking-tight">Create your account</CardTitle>
        <CardDescription>
          Already have an account?
          <a href="/users/log-in" class="font-semibold text-primary hover:underline">Log in</a>
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form :action="action" method="post" class="space-y-4">
          <input type="hidden" name="_csrf_token" :value="csrfToken" />

          <div class="space-y-2">
            <Label for="user_email">Email</Label>
            <Input
              id="user_email"
              name="user[email]"
              type="email"
              :default-value="email ?? ''"
              autocomplete="email"
              placeholder="you@example.com"
              required
            />
          </div>

          <div class="space-y-2">
            <Label for="user_username">Username</Label>
            <Input
              id="user_username"
              name="user[username]"
              :default-value="username ?? ''"
              autocomplete="username"
              placeholder="username"
              required
            />
          </div>

          <div class="space-y-2">
            <Label for="user_password">Password</Label>
            <Input
              id="user_password"
              name="user[password]"
              type="password"
              autocomplete="new-password"
              required
            />
          </div>

          <div class="space-y-2">
            <Label for="user_password_confirmation">Confirm password</Label>
            <Input
              id="user_password_confirmation"
              name="user[password_confirmation]"
              type="password"
              autocomplete="new-password"
              required
            />
          </div>

          <p class="text-xs text-muted-foreground">
            Password must be at least 8 characters and contain at least one lowercase letter (no symbols required).
          </p>
          <p class="text-xs text-muted-foreground">
            Username must be at least 3 characters, letters and numbers only (capitals allowed, no symbols, spaces, or -+).
          </p>

          <Button type="submit" class="w-full">Create account</Button>
        </form>
      </CardContent>
    </Card>
  </div>
</template>
