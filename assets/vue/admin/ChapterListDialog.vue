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
import { X, Trash2, Wrench, Search } from '@lucide/vue'
import { Button } from '@/assets/vue/components/ui/button'
import { Input } from '@/assets/vue/components/ui/input'

export type ChapterRow = {
  id: number
  seriesId: number
  chapterKey: string
  displayNumber: string
  title: string | null
  sortKey: string
  sourceUrl: string
  status: string
  retryCount: number
  lastError: string | null
  publishedAt: string | null
  updatedAt: string | null
  insertedAt: string | null
}

type Pagination = {
  page: number
  pageSize: number
  totalEntries: number
  totalPages: number
  hasPrevious: boolean
  hasNext: boolean
}

const props = defineProps<{
  open: boolean
  seriesTitle: string | null
  seriesId: number | null
  chapters: ChapterRow[]
  pagination: Pagination
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'deleteChapter', row: ChapterRow): void
  (e: 'repairChapter', payload: { id: number; newSourceUrl: string | null }): void
  (e: 'pageChange', page: number): void
  (e: 'pageSizeChange', size: number): void
  (e: 'refresh'): void
}>()

const repairTarget = ref<ChapterRow | null>(null)
const repairUrl = ref('')
const showRepairInput = ref(false)

function formatDate(iso: string | null): string {
  if (!iso) return '-'
  try {
    const d = new Date(iso)
    if (Number.isNaN(d.getTime())) return '-'
    return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
  } catch { return '-' }
}

function statusClass(status: string): string {
  switch (status) {
    case 'available': return 'bg-emerald-100 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-100'
    case 'pending': return 'bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-100'
    case 'processing': return 'bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-100'
    case 'error': return 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-100'
    case 'no_images_found': return 'bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-100'
    default: return 'bg-muted text-muted-foreground'
  }
}

function onDelete(chapter: ChapterRow) {
  emit('deleteChapter', chapter)
}

function onRepairClick(chapter: ChapterRow) {
  repairTarget.value = chapter
  repairUrl.value = ''
  showRepairInput.value = true
}

function confirmRepair() {
  if (!repairTarget.value) return
  const url = repairUrl.value.trim()
  emit('repairChapter', { id: repairTarget.value.id, newSourceUrl: url || null })
  showRepairInput.value = false
  repairTarget.value = null
  repairUrl.value = ''
}

function cancelRepair() {
  showRepairInput.value = false
  repairTarget.value = null
  repairUrl.value = ''
}

watch(() => props.open, open => {
  if (!open) {
    showRepairInput.value = false
    repairTarget.value = null
  }
})

const pageSizeOptions = [25, 50, 75, 100] as const
</script>

<template>
  <DialogRoot :open="open" @update:open="emit('update:open', $event)">
    <DialogPortal>
      <DialogOverlay class="fixed inset-0 z-50 bg-black/40 backdrop-blur-[1px]" />
      <DialogContent
        class="fixed left-1/2 top-1/2 z-50 w-full max-w-5xl max-h-[88vh] -translate-x-1/2 -translate-y-1/2 overflow-hidden rounded-xl border bg-card shadow-xl focus:outline-none flex flex-col"
        @escape-key-down="emit('update:open', false)"
      >
        <!-- Header -->
        <div class="flex items-center justify-between px-5 py-3 border-b shrink-0">
          <div class="min-w-0">
            <DialogTitle class="text-sm font-semibold truncate">
              Chapters — {{ seriesTitle || `Series #${seriesId}` }}
            </DialogTitle>
            <p class="text-xs text-muted-foreground">
              Stable identity: <code class="bg-muted px-1 py-0.5 rounded">chapter_key</code> + <code class="bg-muted px-1 py-0.5 rounded">sort_key</code> — not float. Pagination bounded (max 100).
            </p>
          </div>
          <div class="flex items-center gap-2">
            <Button variant="outline" size="sm" class="h-7" @click="emit('refresh')">
              Refresh
            </Button>
            <DialogClose class="rounded-md p-1.5 text-muted-foreground hover:bg-muted hover:text-foreground" @click="emit('update:open', false)">
              <X class="size-4" />
            </DialogClose>
          </div>
        </div>

        <!-- Body -->
        <div class="flex-1 overflow-auto">
          <!-- Repair input (inline) -->
          <div v-if="showRepairInput && repairTarget" class="px-5 py-3 border-b bg-amber-50 dark:bg-amber-950/20 flex flex-col gap-2">
            <p class="text-xs font-medium">
              Repair chapter {{ repairTarget.displayNumber }} ({{ repairTarget.chapterKey }}) — optional replacement URL
            </p>
            <p class="text-xs text-muted-foreground">
              Leave empty to re-download the existing <code class="bg-muted px-1 rounded">{{ repairTarget.sourceUrl.slice(0, 60) }}…</code>
              with the published config for its host. If you provide a new URL, its host must have a published scraping config.
            </p>
            <div class="flex gap-2">
              <Input v-model="repairUrl" placeholder="https://example.com/manga/title/chapter-10-2 (optional)" class="flex-1 h-8" />
              <Button size="sm" class="h-8" @click="confirmRepair">Enqueue repair</Button>
              <Button variant="outline" size="sm" class="h-8" @click="cancelRepair">Cancel</Button>
            </div>
          </div>

          <div v-if="chapters.length === 0" class="px-5 py-12 text-center">
            <p class="text-sm text-muted-foreground">No chapters found for this series.</p>
            <p class="text-xs text-muted-foreground mt-1">Chapters are created by the series check worker; use “Repair” to re-download a failed chapter.</p>
          </div>

          <div v-else class="w-full overflow-x-auto">
            <table class="w-full text-sm">
              <thead class="bg-muted/50 border-b">
                <tr class="border-b">
                  <th class="h-8 px-3 text-left font-medium text-muted-foreground whitespace-nowrap">Key</th>
                  <th class="h-8 px-3 text-left font-medium text-muted-foreground whitespace-nowrap">Display</th>
                  <th class="h-8 px-3 text-left font-medium text-muted-foreground whitespace-nowrap hidden md:table-cell">Title</th>
                  <th class="h-8 px-3 text-left font-medium text-muted-foreground whitespace-nowrap">Status</th>
                  <th class="h-8 px-3 text-left font-medium text-muted-foreground whitespace-nowrap hidden lg:table-cell">Updated</th>
                  <th class="h-8 px-3 text-left font-medium text-muted-foreground whitespace-nowrap hidden lg:table-cell">Retry</th>
                  <th class="h-8 px-3 text-right font-medium text-muted-foreground whitespace-nowrap">Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="ch in chapters" :key="ch.id" class="border-b hover:bg-muted/30">
                  <td class="px-3 py-2 font-mono text-xs truncate max-w-27.5" :title="ch.chapterKey">{{ ch.chapterKey }}</td>
                  <td class="px-3 py-2 font-medium">{{ ch.displayNumber }}</td>
                  <td class="px-3 py-2 truncate max-w-45 hidden md:table-cell" :title="ch.title || ''">{{ ch.title || '—' }}</td>
                  <td class="px-3 py-2">
                    <span :class="`inline-flex rounded-full px-2 py-0.5 text-xs font-medium capitalize ${statusClass(ch.status)}`">{{ ch.status.replace('_', ' ') }}</span>
                  </td>
                  <td class="px-3 py-2 text-xs hidden lg:table-cell">{{ formatDate(ch.updatedAt) }}</td>
                  <td class="px-3 py-2 text-xs hidden lg:table-cell">
                    <span v-if="ch.retryCount > 0" class="text-amber-700">{{ ch.retryCount }}</span>
                    <span v-else class="text-muted-foreground">0</span>
                  </td>
                  <td class="px-3 py-2">
                    <div class="flex justify-end gap-1">
                      <Button variant="outline" size="sm" class="h-7 px-2 text-xs gap-1" title="Repair — re-download with durable Oban job" @click="onRepairClick(ch)">
                        <Wrench class="size-3" /> Repair
                      </Button>
                      <Button variant="outline" size="sm" class="h-7 w-7 p-0 text-destructive hover:text-destructive" title="Delete — storage + DB, recomputes counters" @click="onDelete(ch)">
                        <Trash2 class="size-3.5" />
                      </Button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <!-- Footer pagination -->
        <div class="flex flex-col sm:flex-row items-center justify-between gap-3 px-5 py-3 border-t bg-muted/10 shrink-0">
          <p class="text-xs text-muted-foreground">
            <template v-if="pagination.totalEntries === 0">No chapters</template>
            <template v-else>
              Showing {{ (pagination.page - 1) * pagination.pageSize + 1 }}–{{ Math.min(pagination.page * pagination.pageSize, pagination.totalEntries) }} of {{ pagination.totalEntries }}
            </template>
          </p>
          <div class="flex items-center gap-2">
            <select
              :value="String(pagination.pageSize)"
              class="h-7 rounded-md border bg-card px-2 text-xs"
              aria-label="Rows per page"
              @change="emit('pageSizeChange', Number.parseInt(($event.target as HTMLSelectElement).value, 10))"
            >
              <option v-for="n in pageSizeOptions" :key="n" :value="String(n)">{{ n }}</option>
            </select>
            <Button variant="ghost" size="sm" :disabled="!pagination.hasPrevious" class="h-7" @click="emit('pageChange', pagination.page - 1)">Previous</Button>
            <span class="text-xs tabular-nums px-2 py-1 rounded bg-muted">Page {{ pagination.page }} / {{ pagination.totalPages }}</span>
            <Button variant="ghost" size="sm" :disabled="!pagination.hasNext" class="h-7" @click="emit('pageChange', pagination.page + 1)">Next</Button>
          </div>
        </div>
      </DialogContent>
    </DialogPortal>
  </DialogRoot>
</template>
