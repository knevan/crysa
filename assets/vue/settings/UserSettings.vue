<script setup lang="ts">
import AccountForm from '@/assets/vue/settings/AccountForm.vue'
import PasswordForm from '@/assets/vue/settings/PasswordForm.vue'
import AvatarUpload from '@/assets/vue/settings/AvatarUpload.vue'
import type { AccountState, PasswordState } from '@/assets/vue/settings/types'
import type { UploadConfig } from 'live_vue'

// Composition surface for the UserSettings island. \
// The LiveView owns all state
defineProps<{
  username: string
  avatarUrl: string | null
  // LiveView upload config (`@uploads.avatar`).
  avatarUpload: UploadConfig
  avatarError: string | null
  account: AccountState
  password: PasswordState
}>()
</script>

<template>
  <div class="mx-auto w-full max-w-200 space-y-7 px-4 py-5 md:space-y-9 md:px-6 md:py-9">
    <div class="flex flex-col items-center gap-1.5 text-center md:gap-2">
      <h1 class="text-xl font-bold tracking-tight text-slate-900 md:text-[26px]">
        Change Profile Settings
      </h1>
      <p class="flex items-center gap-1 text-sm md:text-[15px]">
        <span class="text-[#64748B]">Hello,</span>
        <span class="font-bold text-slate-900">{{ username }}.</span>
      </p>
    </div>

    <AvatarUpload :avatar-url="avatarUrl" :upload-config="avatarUpload" :server-error="avatarError" />

    <AccountForm :account="account" />

    <PasswordForm :password="password" />
  </div>
</template>
