<script setup lang="ts">
import { ref, watch } from 'vue'
import { useLiveVue } from 'live_vue'
import { useDebounceFn } from '@vueuse/core'
import { Input } from '@/assets/vue/components/ui/input'
import { Label } from '@/assets/vue/components/ui/label'
import { Button } from '@/assets/vue/components/ui/button'
import { cn } from '@/assets/vue/lib/utils'
import type { AccountState } from '@/assets/vue/settings/types'

const props = defineProps<{
  account: AccountState
}>()

const live = useLiveVue()

// Local editable copies; the LiveView stays the source of truth and the
// watchers below reconcile after server saves.
const email = ref(props.account.email)
const displayName = ref(props.account.displayName)

watch(
  () => props.account.email,
  (v) => {
    if (v !== email.value) email.value = v
  },
)
watch(
  () => props.account.displayName,
  (v) => {
    if (v !== displayName.value) displayName.value = v
  },
)

function payload() {
  return {
    user: { email: email.value },
    user_profile: { display_name: displayName.value },
  }
}

// Server-side changeset validation (authoritative); debounced so typing stays snappy.
const pushValidate = useDebounceFn(() => {
  live.pushEvent('validate_account', payload())
}, 300)

function submit() {
  live.pushEvent('update_account', payload())
}
</script>

<template>
  <section aria-labelledby="settings-account-title" class="space-y-3">
    <h2 id="settings-account-title" class="text-base font-bold text-slate-900 dark:text-zinc-100 md:text-lg">
      Account Information
    </h2>
    <div class="h-px w-full bg-[#E2E8F0] dark:bg-zinc-800" role="separator" />

    <form class="space-y-3" @submit.prevent="submit">
      <div class="space-y-1.5">
        <Label for="account-display-name" class="text-[13px] font-medium text-[#64748B] dark:text-zinc-400">
          Comment Name
        </Label>
        <Input
          id="account-display-name"
          v-model="displayName"
          type="text"
          placeholder="Enter your display name"
          autocomplete="nickname"
          maxlength="80"
          class="h-11 rounded-lg md:h-10.5"
          :aria-invalid="props.account.displayNameErrors.length > 0"
          :class="cn(props.account.displayNameErrors.length > 0 && 'border-destructive')"
          @update:modelValue="pushValidate"
        />
        <p
          v-if="props.account.displayNameErrors.length > 0"
          class="text-xs text-destructive"
          role="alert"
        >
          {{ props.account.displayNameErrors[0] }}
        </p>
      </div>

      <div class="space-y-1.5">
        <Label for="account-email" class="text-[13px] font-medium text-[#64748B] dark:text-zinc-400">
          Change Email
        </Label>
        <Input
          id="account-email"
          v-model="email"
          type="email"
          placeholder="you@example.com"
          autocomplete="email"
          required
          class="h-11 rounded-lg md:h-10.5"
          :aria-invalid="props.account.emailErrors.length > 0"
          :class="cn(props.account.emailErrors.length > 0 && 'border-destructive')"
          @update:modelValue="pushValidate"
        />
        <p
          v-if="props.account.emailErrors.length > 0"
          class="text-xs text-destructive"
          role="alert"
        >
          {{ props.account.emailErrors[0] }}
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
