<script setup lang="ts">
import { computed } from 'vue'
import { BookmarkX, Clock3 } from '@lucide/vue'

export type BookmarkChapter = {
  displayNumber: string
  chapterKey: string
  publishedAt: string | null
}

export type BookmarkEntry = {
  id: number
  title: string
  slug: string
  coverUrl: string | null
  status: string
  bookmarkedAt: string | null
  lastChapterAt: string | null
  updatedAt: string | null
  latestChapter: BookmarkChapter | null
  lastReading: BookmarkChapter | null
  hasUnread: boolean
}

const coverGradients: Array<[string, string]> = [
  ['#7F1D1D', '#EA580C'],
  ['#0F172A', '#475569'],
  ['#4C1D95', '#EC4899'],
  ['#0F172A', '#15803D'],
  ['#78350F', '#F59E0B'],
  ['#0C4A6E', '#38BDF8'],
  ['#1E1B4B', '#64748B'],
  ['#881337', '#F472B6'],
]

const props = defineProps<{ entry: BookmarkEntry }>()

const emit = defineEmits<{ unbookmark: [id: number] }>()

const gradient = computed<[string, string]>(() => {
  const idx = Math.abs(props.entry.id) % coverGradients.length
  return coverGradients[idx] ?? ['#0F172A', '#475569']
})

const gradientStyle = computed(() => ({
  background: `linear-gradient(135deg, ${gradient.value[0]}, ${gradient.value[1]})`,
}))

const seriesHref = computed(() => `/series/${props.entry.slug}`)

const latestLabel = computed(() =>
  props.entry.latestChapter ? `Ch. ${props.entry.latestChapter.displayNumber}` : '—',
)

const readingLabel = computed(() =>
  props.entry.lastReading ? `Ch. ${props.entry.lastReading.displayNumber}` : '—',
)

// Deep link to the reader so users continue from their last read chapter
// without opening the series page and scrolling for it.
const readingHref = computed(() =>
  props.entry.lastReading ? `${seriesHref.value}/${props.entry.lastReading.chapterKey}` : null,
)

// Same deep-link pattern for the newest chapter: jump straight into reading
// instead of landing on the series page first.
const latestHref = computed(() =>
  props.entry.latestChapter
    ? `${seriesHref.value}/${props.entry.latestChapter.chapterKey}`
    : null,
)

function plural(value: number, one: string, many: string): string {
  return value === 1 ? `1 ${one}` : `${value} ${many}`
}

// Sketch format has no trailing "ago": "17 minutes", "1 hour, 5 minutes".
function elapsedText(): string {
  const iso = props.entry.lastChapterAt ?? props.entry.updatedAt
  if (!iso) return '—'
  const diffMs = Date.now() - new Date(iso).getTime()
  if (Number.isNaN(diffMs) || diffMs < 0) return 'just now'
  const mins = Math.floor(diffMs / 60_000)
  if (mins < 1) return 'just now'
  if (mins < 60) return plural(mins, 'minute', 'minutes')
  const hours = Math.floor(mins / 60)
  if (hours < 24) {
    const rest = mins % 60
    if (rest === 0) return plural(hours, 'hour', 'hours')
    return `${plural(hours, 'hour', 'hours')}, ${plural(rest, 'minute', 'minutes')}`
  }
  const days = Math.floor(hours / 24)
  if (days < 7) return plural(days, 'day', 'days')
  if (days < 30) {
    const weeks = Math.floor(days / 7)
    return plural(weeks, 'week', 'weeks')
  }
  const date = new Date(iso)
  return date.toLocaleDateString()
}
</script>

<template>
  <!-- Card cover, title, time row, meta. -->
  <article class="group flex min-w-0 flex-col gap-2">
    <div class="relative h-55 w-full overflow-hidden rounded-md sm:h-70 lg:h-82.5">
      <a :href="seriesHref" class="block h-full w-full" :aria-label="entry.title">
        <img
          v-if="entry.coverUrl"
          :src="entry.coverUrl"
          :alt="entry.title"
          class="h-full w-full object-cover"
          loading="lazy"
          @error="(e) => ((e.target as HTMLImageElement).style.display = 'none')"
        />
        <div v-else class="h-full w-full" :style="gradientStyle" />
      </a>
      <!-- Badge bar: black 60% overlay, green NOT VIEWED label. -->
      <div v-if="entry.hasUnread" class="absolute inset-x-0 bottom-0 bg-black/60 px-2 py-1">
        <span class="text-[10px] font-extrabold tracking-[0.8px] text-[#4ADE80]">NOT VIEWED</span>
      </div>
      <!-- Remove action -->
      <button
        type="button"
        title="Remove bookmark"
        aria-label="Remove bookmark"
        class="absolute right-1.5 top-1.5 flex size-7 items-center justify-center rounded-md bg-black/50 text-white transition-opacity hover:bg-black/70 focus-visible:opacity-100 md:opacity-0 md:group-hover:opacity-100 md:group-focus-within:opacity-100"
        @click="emit('unbookmark', entry.id)"
      >
        <BookmarkX class="size-4" />
      </button>
    </div>

    <a
      :href="seriesHref"
      class="block w-full truncate text-sm font-bold text-[#0F172A] dark:text-zinc-100 hover:text-[#2563EB] dark:hover:text-blue-400"
      :title="entry.title"
    >
      {{ entry.title }}
    </a>

    <div class="flex items-center gap-1.5">
      <Clock3 class="size-3.5 shrink-0 text-[#94A3B8] dark:text-zinc-500" />
      <span class="truncate text-xs text-[#64748B] dark:text-zinc-400">{{ elapsedText() }}</span>
    </div>

    <div class="h-px w-full bg-[#E2E8F0] dark:bg-zinc-800" />

    <div class="flex w-full items-center gap-2.5">
      <div class="flex min-w-0 flex-1 flex-col gap-0.5">
        <span class="text-[11px] font-medium text-[#94A3B8] dark:text-zinc-500">Latest</span>
        <a
          v-if="latestHref"
          :href="latestHref"
          class="truncate text-[13px] font-bold text-[#2563EB] dark:text-blue-400 hover:underline"
        >
          {{ latestLabel }}
        </a>
        <span v-else class="truncate text-[13px] font-bold text-[#2563EB] dark:text-blue-400">{{ latestLabel }}</span>
      </div>
      <div class="h-8 w-px shrink-0 bg-[#E2E8F0] dark:bg-zinc-800" />
      <div class="flex min-w-0 flex-1 flex-col gap-0.5">
        <span class="text-[11px] font-medium text-[#94A3B8] dark:text-zinc-500">Last Reading</span>
        <a
          v-if="readingHref"
          :href="readingHref"
          class="truncate text-[13px] font-semibold text-[#0F172A] dark:text-zinc-100 hover:text-[#2563EB] dark:hover:text-blue-400 hover:underline"
        >
          {{ readingLabel }}
        </a>
        <span v-else class="truncate text-[13px] font-semibold text-[#0F172A] dark:text-zinc-100">{{ readingLabel }}</span>
      </div>
    </div>
  </article>
</template>
