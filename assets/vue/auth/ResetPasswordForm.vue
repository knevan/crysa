<script setup lang="ts">
import { Card, CardContent, CardHeader, CardTitle } from '@/assets/vue/components/ui/card'
import { Button } from '@/assets/vue/components/ui/button'
import { Input } from '@/assets/vue/components/ui/input'
import { Label } from '@/assets/vue/components/ui/label'

defineProps<{
  action: string
  csrfToken: string
  token: string
}>()
</script>

<template>
  <div class="flex min-h-[calc(100vh-12rem)] items-center justify-center py-8 px-4">
    <div class="w-full max-w-md space-y-6">
    <Card>
      <CardHeader class="space-y-1 text-center">
        <CardTitle class="text-2xl font-semibold tracking-tight">Choose a new password</CardTitle>
      </CardHeader>
      <CardContent>
        <form :action="action" method="post" class="space-y-4">
          <input type="hidden" name="_csrf_token" :value="csrfToken" />

          <div class="space-y-2">
            <Label for="user_password">New password</Label>
            <Input
              id="user_password"
              name="user[password]"
              type="password"
              autocomplete="new-password"
              required
            />
          </div>

          <div class="space-y-2">
            <Label for="user_password_confirmation">Confirm new password</Label>
            <Input
              id="user_password_confirmation"
              name="user[password_confirmation]"
              type="password"
              autocomplete="new-password"
              required
            />
          </div>

          <Button type="submit" variant="outline" class="w-full bg-white hover:bg-zinc-50 text-zinc-900 border-zinc-200 shadow-sm dark:bg-zinc-900 dark:hover:bg-zinc-800 dark:text-white dark:border-zinc-800">Reset password</Button>
        </form>
      </CardContent>
    </Card>
    </div>
  </div>
</template>
