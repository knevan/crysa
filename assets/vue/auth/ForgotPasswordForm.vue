<script setup lang="ts">
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/assets/vue/components/ui/card'
import { Button } from '@/assets/vue/components/ui/button'
import { Input } from '@/assets/vue/components/ui/input'
import { Label } from '@/assets/vue/components/ui/label'

defineProps<{
  action: string
  csrfToken: string
}>()
</script>

<template>
  <div class="mx-auto max-w-md space-y-6">
    <Card>
      <CardHeader class="space-y-1 text-center">
        <CardTitle class="text-2xl font-semibold tracking-tight">Reset your password</CardTitle>
        <CardDescription> Enter your account email and we'll send you a reset link. </CardDescription>
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
              autocomplete="email"
              placeholder="you@example.com"
              required
            />
          </div>

          <Button type="submit" class="w-full">Send reset instructions</Button>
        </form>
      </CardContent>
    </Card>

    <div class="text-center text-sm">
      <a href="/users/log-in" class="text-primary hover:underline underline-offset-4">Back to log in</a>
    </div>
  </div>
</template>
