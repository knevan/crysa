<script setup lang="ts">
import { ref, watch, computed } from 'vue'
import {
  DialogRoot,
  DialogPortal,
  DialogOverlay,
  DialogContent,
  DialogTitle,
  DialogClose,
} from 'reka-ui'
import { X, Clock } from '@lucide/vue'
import { Button } from '@/assets/vue/components/ui/button'
import { Input } from '@/assets/vue/components/ui/input'
import { Label } from '@/assets/vue/components/ui/label'

export type SeriesRow = {
  id: number
  title: string
  publicationStatus: string
  manualCheckIntervalMinutes: number | null
  effectiveIntervalMinutes: number | null
  nextCheckAt: string | null
  lastCheckedAt: string | null
  checkRetryCount: number
  lastError: string | null
}

const props = defineProps<{
  open: boolean
  series: SeriesRow | null
}>()

const emit = defineEmits<{
  (e: 'update:open', v: boolean): void
  (e: 'save', data: { id: number; publicationStatus: string; manualInterval: string | null }): void
}>()

const statuses = ['ongoing', 'hiatus', 'completed', 'discontinued'] as const

const publicationStatus = ref('ongoing')
const manualInterval = ref('') // "" = auto, otherwise number string
const error = ref<string | null>(null)

function formatDate(iso: string | null): string {
  if (!iso) return '—'
  try {
    const d = new Date(iso)
    if (Number.isNaN(d.getTime())) return '—'
    return d.toLocaleString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })
  } catch { return '—' }
}

const effectiveDisplay = computed(() => {
  const s = props.series
  if (!s) return '—'
  if (s.effectiveIntervalMinutes == null) return 'Not scheduled (discontinued)'
  const base = s.manualCheckIntervalMinutes != null ? `manual ${s.manualCheckIntervalMinutes}m` : `status-derived`
  return `${s.effectiveIntervalMinutes} min (${base}${s.checkRetryCount > 0 ? ` ×${Math.pow(2, Math.min(s.checkRetryCount,5))} backoff` : ''})`
})

watch(
  () => props.series,
  s => {
    if (s) {
      publicationStatus.value = s.publicationStatus
      manualInterval.value = s.manualCheckIntervalMinutes != null ? String(s.manualCheckIntervalMinutes) : ''
      error.value = null
    }
  },
  { immediate: true },
)

watch(
  () => props.open,
  o => {
    if (o && props.series) {
      publicationStatus.value = props.series.publicationStatus
      manualInterval.value = props.series.manualCheckIntervalMinutes != null ? String(props.series.manualCheckIntervalMinutes) : ''
      error.value = null
    }
  },
)

function validate(): string | null {
  if (!statuses.includes(publicationStatus.value as any)) return 'Invalid publication status'
  const trimmed = manualInterval.value.trim()
  if (trimmed === '' || trimmed.toLowerCase() === 'auto') return null
  const n = Number(trimmed)
  if (!Number.isInteger(n)) return 'Interval must be an integer'
  if (n < 15 || n > 10_080) return 'Interval must be 15–10 080 minutes (15 min – 7 days)'
  return null
}

function onSave() {
  const msg = validate()
  if (msg) { error.value = msg; return }
  if (!props.series) return
  const trimmed = manualInterval.value.trim()
  const manual = trimmed === '' || trimmed.toLowerCase() === 'auto' ? null : trimmed
  emit('save', { id: props.series.id, publicationStatus: publicationStatus.value, manualInterval: manual })
}

function resetToAuto() {
  manualInterval.value = ''
}
</script>

<template>
  <DialogRoot :open="open" @update:open="emit('update:open', $event)">
    <DialogPortal>
      <DialogOverlay class="fixed inset-0 z-50 bg-black/40 backdrop-blur-[1px]" />
      <DialogContent
        class="fixed left-1/2 top-1/2 z-50 w-full max-w-lg -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-card shadow-xl focus:outline-none flex flex-col"
        @escape-key-down="emit('update:open', false)"
      >
        <div class="flex items-center justify-between px-6 py-4 border-b">
          <DialogTitle class="text-base font-semibold flex items-center gap-2">
            <Clock class="size-4 text-muted-foreground" />
            Check Schedule — {{ series?.title || '' }}
          </DialogTitle>
          <DialogClose class="rounded-md p-1.5 text-muted-foreground hover:bg-muted" @click="emit('update:open', false)">
            <X class="size-4" />
          </DialogClose>
        </div>

        <div class="p-6 space-y-5">
          <div class="rounded-lg border bg-muted/20 p-3 space-y-1">
            <p class="text-xs font-medium">Effective interval</p>
            <p class="text-sm">{{ effectiveDisplay }}</p>
            <p class="text-xs text-muted-foreground">Manual override (minutes) when set; otherwise derived from publication status: ongoing 75–120 min random, hiatus 4h, completed 24h, discontinued unscheduled. Failure backoff ×2 per retry (capped ×32) + ±10% jitter.</p>
            <div class="grid grid-cols-2 gap-2 text-xs pt-2">
              <div>
                <span class="text-muted-foreground">Next check:</span>
                <span class="ml-1 font-mono">{{ formatDate(series?.nextCheckAt || null) }}</span>
              </div>
              <div>
                <span class="text-muted-foreground">Last checked:</span>
                <span class="ml-1 font-mono">{{ formatDate(series?.lastCheckedAt || null) }}</span>
              </div>
              <div>
                <span class="text-muted-foreground">Retry count:</span>
                <span class="ml-1">{{ series?.checkRetryCount ?? 0 }}</span>
              </div>
              <div v-if="series?.lastError" class="col-span-2">
                <span class="text-muted-foreground">Last error:</span>
                <span class="ml-1 text-destructive truncate block" :title="series.lastError">{{ series.lastError }}</span>
              </div>
            </div>
          </div>

          <div class="space-y-1.5">
            <Label class="text-sm font-medium">Publication status</Label>
            <select v-model="publicationStatus" class="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm">
              <option v-for="s in statuses" :key="s" :value="s" class="capitalize">{{ s }}</option>
            </select>
            <p class="text-xs text-muted-foreground">Changing status recomputes <code class="bg-muted px-1 rounded">next_check_at = now + effective_interval + jitter</code> immediately. <code>discontinued</code> becomes unscheduled.</p>
          </div>

          <div class="space-y-1.5">
            <Label class="text-sm font-medium">Manual check interval (minutes)</Label>
            <div class="flex gap-2">
              <Input v-model="manualInterval" placeholder="auto (status-derived)" class="flex-1 h-9" inputmode="numeric" />
              <Button variant="outline" class="h-9 shrink-0" @click="resetToAuto">Reset to auto</Button>
            </div>
            <p class="text-xs text-muted-foreground">15–10 080. Empty = auto (derive from status). Takes effect on save; next check rescheduled with jitter.</p>
          </div>

          <p v-if="error" class="text-sm text-destructive bg-destructive/10 border border-destructive/20 rounded px-3 py-2">{{ error }}</p>
        </div>

        <div class="flex justify-end gap-2 px-6 py-4 border-t bg-muted/10">
          <Button variant="outline" class="h-8" @click="emit('update:open', false)">Cancel</Button>
          <Button class="h-8" @click="onSave">Save schedule</Button>
        </div>
      </DialogContent>
    </DialogPortal>
  </DialogRoot>
</template>
