<script setup lang="ts">
import { ref } from 'vue'
import { useLiveVue } from 'live_vue'
import { useDebounceFn } from '@vueuse/core'
import { Eye, EyeOff } from '@lucide/vue'
import { Input } from '@/assets/vue/components/ui/input'
import { Label } from '@/assets/vue/components/ui/label'
import { Button } from '@/assets/vue/components/ui/button'
import { cn } from '@/assets/vue/lib/utils'
import type { PasswordState } from '@/assets/vue/settings/types'

const props = defineProps<{
  password: PasswordState
}>()

const live = useLiveVue()

// Passwords only flow client → server; the server never echoes values back.
const currentPassword = ref('')
const newPassword = ref('')
const confirmPassword = ref('')

const showCurrent = ref(false)
const showNew = ref(false)
const showConfirm = ref(false)

function payload() {
  return {
    user: {
      current_password: currentPassword.value,
      password: newPassword.value,
      password_confirmation: confirmPassword.value,
    },
  }
}

// Server-side changeset validation; debounced so typing stays snappy.
const pushValidate = useDebounceFn(() => {
  live.pushEvent('validate_password', payload())
}, 300)

function submit() {
  live.pushEvent('update_password', payload())
}

function firstError(list: string[]): string | null {
  return list.length > 0 ? list[0] : null
}
</script>

<template>
  <section aria-labelledby="settings-password-title" class="space-y-3">
    <h2 id="settings-password-title" class="text-base font-bold text-slate-900 dark:text-zinc-100 md:text-lg">
      Change Password
    </h2>
    <div class="h-px w-full bg-[#E2E8F0] dark:bg-zinc-800" role="separator" />

    <form class="space-y-3" @submit.prevent="submit">
      <div class="space-y-1.5">
        <Label for="password-current" class="text-[13px] font-medium text-[#64748B] dark:text-zinc-400">
          Current password
        </Label>
        <div class="relative">
          <Input
            id="password-current"
            v-model="currentPassword"
            :type="showCurrent ? 'text' : 'password'"
            autocomplete="current-password"
            required
            class="h-11 rounded-lg pr-10 md:h-10.5"
            :aria-invalid="props.password.errors.currentPassword.length > 0"
            :class="cn(props.password.errors.currentPassword.length > 0 && 'border-destructive')"
            @update:modelValue="pushValidate"
          />
          <button
            type="button"
            class="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground transition-colors hover:text-foreground"
            tabindex="-1"
            :aria-label="showCurrent ? 'Hide password' : 'Show password'"
            @click="showCurrent = !showCurrent"
          >
            <EyeOff v-if="showCurrent" class="h-4 w-4" />
            <Eye v-else class="h-4 w-4" />
          </button>
        </div>
        <p
          v-if="firstError(props.password.errors.currentPassword)"
          class="text-xs text-destructive"
          role="alert"
        >
          {{ firstError(props.password.errors.currentPassword) }}
        </p>
      </div>

      <div class="space-y-1.5">
        <Label for="password-new" class="text-[13px] font-medium text-[#64748B] dark:text-zinc-400">
          New Password
        </Label>
        <div class="relative">
          <Input
            id="password-new"
            v-model="newPassword"
            :type="showNew ? 'text' : 'password'"
            placeholder="More than 8 characters"
            autocomplete="new-password"
            required
            class="h-11 rounded-lg pr-10 md:h-10.5"
            :aria-invalid="props.password.errors.password.length > 0"
            :class="cn(props.password.errors.password.length > 0 && 'border-destructive')"
            @update:modelValue="pushValidate"
          />
          <button
            type="button"
            class="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground transition-colors hover:text-foreground"
            tabindex="-1"
            :aria-label="showNew ? 'Hide password' : 'Show password'"
            @click="showNew = !showNew"
          >
            <EyeOff v-if="showNew" class="h-4 w-4" />
            <Eye v-else class="h-4 w-4" />
          </button>
        </div>
        <p
          v-if="firstError(props.password.errors.password)"
          class="text-xs text-destructive"
          role="alert"
        >
          {{ firstError(props.password.errors.password) }}
        </p>
      </div>

      <div class="space-y-1.5">
        <Label for="password-confirm" class="text-[13px] font-medium text-[#64748B] dark:text-zinc-400">
          Confirm Password
        </Label>
        <div class="relative">
          <Input
            id="password-confirm"
            v-model="confirmPassword"
            :type="showConfirm ? 'text' : 'password'"
            placeholder="Confirm your new password"
            autocomplete="new-password"
            required
            class="h-11 rounded-lg pr-10 md:h-10.5"
            :aria-invalid="props.password.errors.passwordConfirmation.length > 0"
            :class="cn(props.password.errors.passwordConfirmation.length > 0 && 'border-destructive')"
            @update:modelValue="pushValidate"
          />
          <button
            type="button"
            class="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground transition-colors hover:text-foreground"
            tabindex="-1"
            :aria-label="showConfirm ? 'Hide password' : 'Show password'"
            @click="showConfirm = !showConfirm"
          >
            <EyeOff v-if="showConfirm" class="h-4 w-4" />
            <Eye v-else class="h-4 w-4" />
          </button>
        </div>
        <p
          v-if="firstError(props.password.errors.passwordConfirmation)"
          class="text-xs text-destructive"
          role="alert"
        >
          {{ firstError(props.password.errors.passwordConfirmation) }}
        </p>
      </div>

      <div class="pt-1">
        <Button
          type="submit"
          class="h-11 w-full rounded-lg bg-[#2563EB] px-5.5 py-2.25 text-sm font-bold text-white hover:bg-[#1D4ED8] md:w-auto md:text-[13px]"
        >
          Save
        </Button>
      </div>
    </form>
  </section>
</template>
