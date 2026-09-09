<script setup lang="ts">
import { ref, watch, onBeforeUnmount } from 'vue'
import { useLiveUpload, useLiveVue, type UploadConfig, type UploadOptions } from 'live_vue'
import { UserRound } from '@lucide/vue'

const props = defineProps<{
  avatarUrl: string | null
  // LiveView upload config (`@uploads.avatar`).
  uploadConfig: UploadConfig
  serverError: string | null
}>()

const live = useLiveVue()
const fileInput = ref<HTMLInputElement | null>(null)
const previewUrl = ref<string | null>(null)
// Local error for client-side handoff failures (e.g. file could not be
// queued for upload); server validation still arrives via serverError.
const localError = ref<string | null>(null)
// Guards against pushing `save_avatar` twice for the same entry.
const savePushedFor = ref<string | null>(null)

// Buffered in LiveView temp (RAM/disk) via allow_upload, then moved to object
// storage by the `save_avatar` event — same flow as AdminDashboard cover upload.
const { entries, addFiles } = useLiveUpload(() => props.uploadConfig, {
  changeEvent: 'validate_avatar',
  submitEvent: undefined,
} as unknown as UploadOptions)

const activeEntry = () => entries.value?.[0] as
  | { ref?: string; client_name?: string; progress?: number }
  | undefined

function onPickFile() {
  fileInput.value?.click()
}

function onFileChange(e: Event) {
  const input = e.target as HTMLInputElement
  const file = input.files?.[0] ?? null
  // Reset the input so picking the same file again still fires change.
  input.value = ''
  if (!file) return
  if (previewUrl.value) URL.revokeObjectURL(previewUrl.value)
  previewUrl.value = URL.createObjectURL(file)
  savePushedFor.value = null
  localError.value = null
  try {
    addFiles([file])
  } catch (_) {
    // Fallback: LiveView's hidden input still captures via native change.
    // If the file never reaches the server, entries stay empty and no
    // auto-save fires — surface that instead of hanging on "Uploading…".
    localError.value = 'Could not queue the file for upload. Please try again.'
  }
}

// Auto-save once the entry is fully buffered; the sketch exposes a single
// "Choose File" button, so no second confirmation step exists.
watch(
  () => activeEntry()?.progress,
  (progress) => {
    const entry = activeEntry()
    const ref = entry?.ref ?? entry?.client_name ?? null
    if (progress === 100 && ref && savePushedFor.value !== ref) {
      savePushedFor.value = ref
      live.pushEvent('save_avatar', {})
    }
  },
)

onBeforeUnmount(() => {
  if (previewUrl.value) URL.revokeObjectURL(previewUrl.value)
})

const shownAvatar = () => previewUrl.value ?? props.avatarUrl
</script>

<template>
  <section aria-labelledby="settings-avatar-title" class="space-y-3">
    <h2 id="settings-avatar-title" class="text-base font-bold text-slate-900 md:text-lg">
      Change Avatar
    </h2>
    <div class="h-px w-full bg-[#E2E8F0]" role="separator" />
    <p class="text-xs text-[#64748B] md:text-[13px]">
      Use the form below to change your avatar.
    </p>

    <div class="flex flex-col items-center gap-2.5 md:items-start">
      <div
        class="flex h-19 w-19 items-center justify-center overflow-hidden rounded-full border border-[#E2E8F0] bg-[#F1F5F9] md:h-21 md:w-21"
      >
        <img
          v-if="shownAvatar()"
          :src="shownAvatar() ?? ''"
          alt="Your avatar"
          class="h-full w-full object-cover"
        />
        <UserRound v-else class="h-12 w-12 text-slate-400 md:h-12 md:w-12" />
      </div>

      <div class="flex flex-col items-center gap-2 md:items-start">
        <button
          type="button"
          class="inline-flex cursor-pointer items-center justify-center rounded-lg bg-[#1E293B] px-4 py-2 text-xs font-bold text-white transition-colors hover:bg-slate-700 md:px-3 md:py-1.5"
          @click="onPickFile"
        >
          Choose File
        </button>
        <input
          ref="fileInput"
          type="file"
          accept="image/jpeg,image/png,image/webp,image/gif"
          class="sr-only"
          tabindex="-1"
          @change="onFileChange"
        />
        <p
          v-if="activeEntry() && (activeEntry()?.progress ?? 100) < 100"
          class="text-xs text-[#64748B]"
          role="status"
        >
          Uploading… {{ activeEntry()?.progress ?? 0 }}%
        </p>
        <p v-if="serverError" class="text-xs text-destructive" role="alert">
          {{ serverError }}
        </p>
        <p v-else-if="localError" class="text-xs text-destructive" role="alert">
          {{ localError }}
        </p>
        <p class="text-xs text-[#64748B]">Maximum 2 MB. JPEG, PNG, WebP, or GIF.</p>
      </div>
    </div>
  </section>
</template>
