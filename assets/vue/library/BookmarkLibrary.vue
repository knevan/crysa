<script setup lang="ts">
import { computed, onMounted, ref, useTemplateRef, watch } from 'vue'
import { useLiveVue } from 'live_vue'
import { Bookmark as BookmarkIcon, BookOpen } from '@lucide/vue'
import BookmarkCard, { type BookmarkEntry } from '@/assets/vue/library/BookmarkCard.vue'
import BookmarkToolbar from '@/assets/vue/library/BookmarkToolbar.vue'

type Pagination = {
  page: number
  pageSize: number
  totalEntries: number
  totalPages: number
  hasPrevious: boolean
  hasNext: boolean
}

const props = defineProps<{
  entries: BookmarkEntry[]
  pagination: Pagination
  status: string
  sortBy: string
  order: string
  currentUser: { id: number; username: string } | null
}>()

const live = useLiveVue()

// Local copy enables optimistic unbookmark (instant removal, server reconciles).
const localEntries = ref<BookmarkEntry[]>([...(props.entries ?? [])])
// Deep watch is required: LiveVue applies prop updates as in-place JSON-patch
// operations (element replace/splice, array reference unchanged), so a
// reference-only watcher would never fire and the grid would stay stale
// until a full page reload.
watch(
  () => props.entries,
  (next) => {
    localEntries.value = [...(next ?? [])]
  },
  { deep: true },
)

const totalPages = computed(() => Math.max(1, Math.floor(props.pagination?.totalPages ?? 1)))
const currentPage = computed(() => {
  const raw = Math.floor(Number(props.pagination?.page) || 1)
  return Math.min(Math.max(raw, 1), totalPages.value)
})

// Segmented window matching the sketch: 1 2 3 4 5 … 8 on page 1.
const pageWindow = computed<Array<number | '…'>>(() => {
  const total = totalPages.value
  const current = currentPage.value
  if (total <= 7) return Array.from({ length: total }, (_, i) => i + 1)
  if (current <= 4) return [1, 2, 3, 4, 5, '…', total]
  if (current >= total - 3) return [1, '…', total - 4, total - 3, total - 2, total - 1, total]
  return [1, '…', current - 1, current, current + 1, '…', total]
})

function onFilter(next: { status: string; sortBy: string; order: string }) {
  live.pushEvent('bookmarks_filter', { status: next.status, sort_by: next.sortBy, order: next.order })
}

function goToPage(page: number) {
  const target = Math.min(Math.max(Math.floor(page) || 1, 1), totalPages.value)
  if (target !== currentPage.value) live.pushEvent('bookmarks_page', { page: target })
}

function unbookmark(id: number) {
  localEntries.value = localEntries.value.filter((e) => e.id !== id)
  live.pushEvent('unbookmark', { id })
}

// Client-side CSV export of the visible page ("Download" in the sketch).
// No server roundtrip; filename carries the active filter for traceability.
function downloadVisible() {
  const rows = localEntries.value.map((e) => ({
    title: e.title,
    slug: e.slug,
    url: `/series/${e.slug}`,
    status: e.status,
    latest: e.latestChapter ? `Ch. ${e.latestChapter.displayNumber}` : '',
    last_reading: e.lastReading ? `Ch. ${e.lastReading.displayNumber}` : '',
  }))
  const header = 'title,slug,url,status,latest,last_reading'
  const escape = (v: string) => `"${v.replace(/"/g, '""')}"`
  const body = rows
    .map((r) => [r.title, r.slug, r.url, r.status, r.latest, r.last_reading].map(escape).join(','))
    .join('\n')
  const lines = [header, body].filter((line) => line.length > 0)
  const blob = new Blob([`${lines.join('\n')}\n`], {
    type: 'text/csv;charset=utf-8',
  })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `bookmarks-${props.status}-${props.sortBy}-${props.order}-p${currentPage.value}.csv`
  document.body.appendChild(a)
  a.click()
  a.remove()
  URL.revokeObjectURL(url)
}

// Island-mount safety net: report mount when visible so reconnects reconcile 
// the server handler is idempotent.
const libraryRoot = useTemplateRef<HTMLDivElement>('libraryRoot')
onMounted(() => {
  if (libraryRoot.value && libraryRoot.value.offsetParent !== null) {
    live.pushEvent('bookmarks_opened', {})
  }
})

watch(currentPage, () => {
  libraryRoot.value?.scrollIntoView({ block: 'start' })
})

function pageButtonClass(page: number): string {
  const base =
    'flex h-9 w-10 items-center justify-center rounded-lg border text-[13px] font-semibold transition-colors'

  return page === currentPage.value
    ? `${base} border-[#0F172A] bg-[#0F172A] text-white`
    : `${base} border-[#E2E8F0] bg-white text-[#0F172A] hover:bg-[#F8F9FB]`
}
</script>

<template>
  <!-- Page Content -->
  <div ref="libraryRoot" class="min-h-screen bg-[#F8F9FB]">
    <div class="mx-auto w-full max-w-7xl px-4 py-8 sm:px-6 md:py-8">
      <!-- Title Block -->
      <div class="flex w-full flex-col items-center gap-1.5 text-center">
        <h1 class="text-2xl font-bold text-[#0F172A]">Your Bookmarked Manga Library</h1>
        <p class="text-sm text-[#64748B]">The list of Manga you subscribe to follow.</p>
      </div>

      <!-- Toolbar -->
      <div class="mt-4.5 flex w-full justify-end">
        <BookmarkToolbar
          :status="props.status"
          :sort-by="props.sortBy"
          :order="props.order"
          @filter="onFilter"
          @download="downloadVisible"
        />
      </div>

      <!-- Divider Strong -->
      <div class="mt-4.5 h-0.5 w-full bg-[#0F172A]" />

      <!-- Grid -->
      <div v-if="localEntries.length > 0" class="mt-7 grid w-full grid-cols-2 gap-4 md:gap-5 lg:grid-cols-4">
        <BookmarkCard
          v-for="entry in localEntries"
          :key="entry.id"
          :entry="entry"
          @unbookmark="unbookmark"
        />
      </div>

      <!-- Empty state, required for zero-bookmark users. -->
      <div
        v-else
        class="mt-7 flex w-full flex-col items-center gap-3 rounded-xl border border-[#E2E8F0] bg-white px-6 py-14 text-center"
      >
        <div class="flex size-12 items-center justify-center rounded-xl border border-[#E2E8F0] bg-[#F8F9FB]">
          <BookmarkIcon class="size-5 text-[#94A3B8]" />
        </div>
        <p class="text-sm font-bold text-[#0F172A]">No bookmarks yet</p>
        <p class="max-w-[320px] text-xs leading-5 text-[#64748B]">
          Series you bookmark will appear here with their latest chapter.
        </p>
        <a
          href="/series"
          class="mt-1 inline-flex h-9 items-center gap-2 rounded-lg bg-[#0F172A] px-4 text-xs font-bold text-white hover:bg-[#1E293B]"
        >
          <BookOpen class="size-3.5" />
          Browse series
        </a>
      </div>

      <!-- Bottom Pagination: segmented « 1 … 8 » -->
      <nav
        v-if="totalPages > 1"
        class="mt-8 flex w-full items-center justify-center gap-2"
        aria-label="Bookmark pages"
      >
        <button
          type="button"
          aria-label="Previous page"
          :disabled="!props.pagination.hasPrevious"
          class="flex h-9 w-10 items-center justify-center rounded-lg border border-[#E2E8F0] bg-[#F8FAFC] text-sm text-[#94A3B8] transition-colors hover:bg-white disabled:cursor-not-allowed disabled:opacity-50"
          @click="goToPage(currentPage - 1)"
        >
          «
        </button>
        <template v-for="(entry, i) in pageWindow" :key="entry === '…' ? `gap-${i}` : entry">
          <span v-if="entry === '…'" class="flex h-9 w-11 items-center justify-center text-sm text-[#94A3B8]">
            …
          </span>
          <button
            v-else
            type="button"
            :aria-label="`Page ${entry}`"
            :aria-current="entry === currentPage ? 'page' : undefined"
            :class="pageButtonClass(entry)"
            @click="goToPage(entry)"
          >
            {{ entry }}
          </button>
        </template>
        <button
          type="button"
          aria-label="Next page"
          :disabled="!props.pagination.hasNext"
          class="flex h-9 w-10 items-center justify-center rounded-lg border border-[#E2E8F0] bg-white text-sm text-[#0F172A] transition-colors hover:bg-[#F8F9FB] disabled:cursor-not-allowed disabled:opacity-50"
          @click="goToPage(currentPage + 1)"
        >
          »
        </button>
      </nav>

      <!-- Footer -->
      <div class="mt-10 border-t border-[#E2E8F0] bg-white py-5 text-center">
        <p class="hidden text-xs text-[#94A3B8] sm:block">
          © 2025 Crysa • Crafted for manga lovers • Terms • Privacy • DMCA
        </p>
        <p class="text-xs text-[#94A3B8] sm:hidden">© 2025 Crysa • Terms • Privacy</p>
      </div>
    </div>
  </div>
</template>
