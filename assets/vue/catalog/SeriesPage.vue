<script setup lang="ts">
import { ref, computed, watch, onMounted, onBeforeUnmount } from 'vue'
import { useLiveVue } from 'live_vue'
import { useDebounceFn } from '@vueuse/core'
import {
  Search,
  BookOpen,
  Eye,
  Bookmark,
  Activity,
  Clock3,
  Sparkles,
  Star,
  StarHalf,
  Share2,
  Flag,
  EllipsisVertical,
  Bell,
  MessageCircle,
  Bold,
  Italic,
  Link2,
  Smile,
  Image as ImageIcon,
  Send,
  ChevronDown,
  Lock,
} from '@lucide/vue'
import { Button } from '@/assets/vue/components/ui/button'
import { Input } from '@/assets/vue/components/ui/input'
import { Separator } from '@/assets/vue/components/ui/separator'
import CommentTree from '@/assets/vue/comments/CommentTree.vue'
import type { CommentNodeData } from '@/assets/vue/comments/CommentNode.vue'

type Series = {
  id: number
  title: string
  slug: string
  description: string | null
  coverUrl: string | null
  sourceUrl: string | null
  publicationStatus: string
  chapterCount: number
  viewCount: number
  bookmarkCount: number
  ratingCount: number
  ratingSum: number
  lastChapterAt: string | null
  updatedAt: string | null
  insertedAt: string | null
}

type Author = { id: number; name: string }
type Category = { id: number; name: string }
type RatingSummary = { count: number; sum: number; average: number | null }
type RatingDist = { rating: number; count: number; percent: number }

type Chapter = {
  id: number
  chapterKey: string
  displayNumber: string
  title: string | null
  sortKey: string
  publishedAt: string | null
}

type Comment = {
  id: number
  bodyMarkdown: string | null
  bodyHtml: string
  voteScore: number
  upCount: number
  downCount: number
  insertedAt: string | null
  user: { id: number; username: string } | null
  parentId: number | null
}

// Tree node is the recursive shape used by CommentTree
type CommentTreeNode = CommentNodeData

type Pagination = {
  page: number
  pageSize: number
  totalEntries: number
  totalPages: number
  hasPrevious: boolean
  hasNext: boolean
}

const props = defineProps<{
  series: Series
  authors: Author[]
  categories: Category[]
  stats: { chapters: number; views: number; bookmarked: number; status: string }
  coverUrl: string | null
  description: string | null
  ratingSummary: RatingSummary
  ratingDistribution: RatingDist[]
  bookmarked: boolean
  userRating: number | null
  currentUser: { id: number; username: string } | null
  latestChapter: Chapter | null
  chapters: Chapter[]
  chapterPagination: Pagination
  chapterQuery: string
  chapterSort: string
  comments: Comment[]
  commentTree: CommentTreeNode[]
  commentPagination: Pagination
  commentSort: string
  commentCount: number
  threadId: number | null
  isThreadView: boolean
}>()

const live = useLiveVue()

// --- Description toggle ---
const expanded = ref(false)
const description = computed(() => props.description || 'No description available.')
const isLongDescription = computed(() => (props.description || '').length > 140)
const displayDescription = computed(() => {
  if (!isLongDescription.value || expanded.value) return description.value
  return description.value.slice(0, 140) + '…'
})

// --- Stats ---
const statusLabel = computed(() => {
  const s = props.stats.status
  return s.charAt(0).toUpperCase() + s.slice(1)
})
const statusClass = computed(() => {
  switch (props.stats.status) {
    case 'ongoing':
      return 'text-emerald-600'
    case 'completed':
      return 'text-sky-600'
    case 'hiatus':
      return 'text-amber-600'
    default:
      return 'text-muted-foreground'
  }
})

function formatRelative(iso: string | null): string {
  if (!iso) return '—'
  const d = new Date(iso)
  const diff = Date.now() - d.getTime()
  const mins = Math.floor(diff / 60000)
  if (mins < 1) return 'just now'
  if (mins < 60) return `${mins} minutes ago`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `${hours} hours ago`
  const days = Math.floor(hours / 24)
  if (days < 7) return `${days} days ago`
  return d.toLocaleDateString()
}

const lastUpdateText = computed(() => {
  // Prefer lastChapterAt, fallback to updatedAt
  const iso = props.series.lastChapterAt || props.series.updatedAt
  return formatRelative(iso)
})

// --- Bookmark ---
const localBookmarked = ref(props.bookmarked)
const localBookmarkCount = ref(props.stats.bookmarked)
watch(() => props.bookmarked, v => (localBookmarked.value = v))
watch(() => props.stats.bookmarked, v => (localBookmarkCount.value = v))

function toggleBookmark() {
  if (!props.currentUser) {
    // Redirect to login
    window.location.href = '/auth/login'
    return
  }
  const was = localBookmarked.value
  localBookmarked.value = !was
  localBookmarkCount.value = Math.max(0, localBookmarkCount.value + (was ? -1 : 1))
  live.pushEvent('toggle_bookmark', {})
}

// --- Rating —--
const localUserRating = ref<number | null>(props.userRating)
const localRatingSummary = ref<RatingSummary>({ ...props.ratingSummary })
const localRatingDistribution = ref<RatingDist[]>([...props.ratingDistribution])
const ratingPending = ref(false)

watch(() => props.userRating, v => (localUserRating.value = v))
watch(() => props.ratingSummary, v => (localRatingSummary.value = { ...v }), { deep: true })
watch(() => props.ratingDistribution, v => (localRatingDistribution.value = [...v]), { deep: true })

const averageDisplay = computed(() => {
  const avg = localRatingSummary.value.average
  return avg != null ? (avg * 2).toFixed(1) : '—'
})
const votesText = computed(() => `${localRatingSummary.value.count} votes`)
const displayDistribution = computed(() => localRatingDistribution.value)

const hoverRating = ref<number | null>(null)
const displayRating = computed(() => hoverRating.value ?? localUserRating.value ?? 0)

function setHover(e: MouseEvent, star: number) {
  const target = e.currentTarget as HTMLElement
  const rect = target.getBoundingClientRect()
  const x = e.clientX - rect.left
  const isHalf = x < rect.width / 2
  hoverRating.value = isHalf ? star - 0.5 : star
}

function clearHover() {
  hoverRating.value = null
}

function handleStarClick(e: MouseEvent, star: number) {
  const target = e.currentTarget as HTMLElement
  const rect = target.getBoundingClientRect()
  const x = e.clientX - rect.left
  const isHalf = x < rect.width / 2
  const value = isHalf ? star - 0.5 : star
  rate(value)
}

function applyRating(newRating: number | null) {
  const prev = localUserRating.value
  const summary = { ...localRatingSummary.value }
  let dist = [...localRatingDistribution.value]
  // helper to bucket star 1..5
  const bucket = (r: number) => Math.min(5, Math.max(1, Math.ceil(r)))
  if (prev == null && newRating != null) {
    // first rating
    summary.count += 1
    summary.sum = (summary.sum || 0) + newRating
    summary.average = summary.sum / summary.count
    // distribution
    const b = bucket(newRating)
    dist = dist.map(row => row.rating === b ? { ...row, count: row.count + 1 } : row)
  } else if (prev != null && newRating != null) {
    summary.sum = (summary.sum || 0) - prev + newRating
    summary.average = summary.count > 0 ? summary.sum / summary.count : null
    const prevB = bucket(prev)
    const newB = bucket(newRating)
    if (prevB !== newB) {
      dist = dist.map(row => {
        if (row.rating === prevB) return { ...row, count: Math.max(0, row.count - 1) }
        if (row.rating === newB) return { ...row, count: row.count + 1 }
        return row
      })
    }
  } else if (prev != null && newRating == null) {
    summary.count = Math.max(0, summary.count - 1)
    summary.sum = Math.max(0, (summary.sum || 0) - prev)
    summary.average = summary.count > 0 ? summary.sum / summary.count : null
    const b = bucket(prev)
    dist = dist.map(row => row.rating === b ? { ...row, count: Math.max(0, row.count - 1) } : row)
  }
  // recompute percents
  const total = dist.reduce((s, r) => s + r.count, 0)
  dist = dist.map(r => ({ ...r, percent: total > 0 ? Math.round((r.count / total) * 1000) / 10 : 0 }))
  // keep sorted 5..1
  dist.sort((a, b) => b.rating - a.rating)
  localRatingSummary.value = summary
  localRatingDistribution.value = dist
}

function rate(value: number) {
  if (!props.currentUser) {
    window.location.href = '/auth/login'
    return
  }
  if (ratingPending.value) return
  // clamp to 0.5 steps 1..5
  const v = Math.round(value * 2) / 2
  if (v < 1 || v > 5) return
  const prev = localUserRating.value
  localUserRating.value = v
  applyRating(v)
  ratingPending.value = true
  const payload: any = live.pushEvent('rate_series', { rating: v })
  Promise.resolve(payload).catch(() => {
    localUserRating.value = prev
    localRatingSummary.value = { ...props.ratingSummary }
    localRatingDistribution.value = [...props.ratingDistribution]
  }).finally(() => {
    ratingPending.value = false
  })
}

function unrate() {
  if (!props.currentUser) return
  if (ratingPending.value) return
  const prev = localUserRating.value
  const prevSummary = { ...localRatingSummary.value }
  const prevDist = [...localRatingDistribution.value]
  localUserRating.value = null
  applyRating(null)
  ratingPending.value = true
  const payload: any = live.pushEvent('unrate_series', {})
  Promise.resolve(payload).catch(() => {
    localUserRating.value = prev
    localRatingSummary.value = prevSummary
    localRatingDistribution.value = prevDist
  }).finally(() => {
    ratingPending.value = false
  })
}

// Ellipsis dropdown for rating card
const showRateMenu = ref(false)
const ellipsisRef = ref<HTMLElement | null>(null)
const dropdownStyle = ref<Record<string, string>>({})

function updateDropdownPosition() {
  if (!ellipsisRef.value) return
  const rect = ellipsisRef.value.getBoundingClientRect()
  const dropdownWidth = 144 // w-36
  const left = Math.min(Math.max(8, rect.right - dropdownWidth), window.innerWidth - dropdownWidth - 8)
  dropdownStyle.value = {
    top: `${rect.bottom + 6}px`,
    left: `${left}px`,
  }
}

function toggleRateMenu() {
  showRateMenu.value = !showRateMenu.value
  if (showRateMenu.value) setTimeout(updateDropdownPosition, 0)
}

function onClickOutside(e: MouseEvent) {
  if (!showRateMenu.value) return
  const target = e.target as HTMLElement
  const insideEllipsis = ellipsisRef.value?.contains(target)
  const insideDropdown = target.closest('[data-rate-dropdown]')
  if (!insideEllipsis && !insideDropdown) showRateMenu.value = false
}

function onWindowChange() {
  if (showRateMenu.value) updateDropdownPosition()
}

onMounted(() => {
  window.addEventListener('click', onClickOutside)
  window.addEventListener('resize', onWindowChange)
  window.addEventListener('scroll', onWindowChange, true)
})

onBeforeUnmount(() => {
  window.removeEventListener('click', onClickOutside)
  window.removeEventListener('resize', onWindowChange)
  window.removeEventListener('scroll', onWindowChange, true)
})

function handleShare() {
  showRateMenu.value = false
  const url = window.location.href
  const title = props.series.title
  if (navigator.share) {
    navigator.share({ title, url }).catch(() => {})
  } else if (navigator.clipboard) {
    navigator.clipboard.writeText(url).then(() => {
      // No toast system here; rely on native feedback
    })
  }
}

function handleReport() {
  showRateMenu.value = false
  // Placeholder: report flow is handled via moderation UI; for now show alert
  // In production this would open a report dialog.
  alert('Report feature will be available soon. Please contact moderation if needed.')
}

// --- Chapters ---
const chapterQuery = ref(props.chapterQuery || '')
watch(() => props.chapterQuery, v => {
  if (v !== chapterQuery.value) chapterQuery.value = v
})

const debouncedChaptersSearch = useDebounceFn((value: string) => {
  live.pushEvent('search_chapters', { q: value })
}, 350)

watch(chapterQuery, v => debouncedChaptersSearch(v))

const chapterSort = ref(props.chapterSort || 'newest')
watch(() => props.chapterSort, v => (chapterSort.value = v))

function toggleChapterSort() {
  const next = chapterSort.value === 'newest' ? 'oldest' : 'newest'
  chapterSort.value = next
  live.pushEvent('sort_chapters', { sort: next })
}

function goChapterPage(page: number) {
  live.pushEvent('chapter_page_change', { page })
}

const chaptersForList = computed(() => [...(props.chapters ?? [])])

// Latest chapter for actions
const latestChapterLabel = computed(() => {
  if (!props.latestChapter) return 'Ch. —'
  return `Ch. ${props.latestChapter.displayNumber}`
})

const firstChapterLabel = computed(() => {
  // Oldest chapter is last in newest-sorted list, but we have no firstChapter prop.
  // Use latest as fallback; ideally LiveView would provide firstChapter.
  // For now show same as latest if available.
  if (props.chapters.length === 0) return 'Ch. —'
  // If sorted newest, the oldest is at the end
  const oldest = [...props.chapters].sort((a, b) => a.sortKey.localeCompare(b.sortKey))[0]
  return oldest ? `Ch. ${oldest.displayNumber}` : latestChapterLabel.value
})

// --- Comments (threaded tree) ---
// All interactive comment logic (composer, vote, reply, sort, pagination) is
// encapsulated in <CommentTree>. SeriesPage stays a thin composition surface
// and only forwards SSR-propagated props.
const commentTreeNodes = computed(() => props.commentTree ?? [])

// --- Helpers for display ---
function formatChapterDate(iso: string | null): string {
  if (!iso) return ''
  const d = new Date(iso)
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })
}

function authorDisplay(): string {
  if (props.authors.length === 0) return 'Unknown'
  return props.authors.map(a => a.name).join(', ')
}
</script>

<template>
  <div class="min-h-screen bg-background">
    <!-- Content container: mobile 390, expand to 680 on larger screens -->
    <div class="mx-auto w-full max-w-[390px] px-3 py-4 md:max-w-[680px] md:px-4 lg:max-w-[720px]">
      <!-- Series Card M — overflow-visible so ellipsis dropdown is not clipped (feedback #1) -->
      <div class="rounded-2xl border bg-card shadow-[0_8px_20px_rgba(15,23,42,0.06)] overflow-visible">
        <div class="p-4 flex flex-col gap-3.5">
          <!-- Breadcrumb M -->
          <nav class="flex items-center gap-1 text-[10px] text-muted-foreground">
            <a href="/" class="hover:text-foreground">Home</a>
            <span>/</span>
            <a href="/series" class="hover:text-foreground">Series</a>
            <span>/</span>
            <span class="font-semibold text-foreground truncate">{{ series.title }}</span>
          </nav>

          <div class="flex flex-col gap-3.5 md:flex-row md:gap-6">
            <!-- Cover Wrap M — full width on mobile (345x328), fixed 236 on desktop -->
            <div class="flex flex-col items-center gap-2 md:w-[236px] md:shrink-0">
              <div class="relative w-full overflow-hidden rounded-xl border bg-muted">
                <!-- Mobile 345/328, desktop 3/4 aspect via md -->
                <div class="aspect-[345/328] md:aspect-[3/4] w-full relative">
                  <img
                    v-if="coverUrl"
                    :src="coverUrl"
                    :alt="series.title"
                    class="h-full w-full object-cover"
                    loading="eager"
                    @error="(e) => ((e.target as HTMLImageElement).style.display='none')"
                  />
                  <div v-else class="h-full w-full flex items-center justify-center bg-muted">
                    <ImageIcon class="size-10 text-muted-foreground/40" />
                  </div>
                  <div
                    v-if="stats.status === 'ongoing' && stats.chapters > 0"
                    class="absolute left-2 top-2 rounded-lg bg-red-500 px-2 py-1 text-[9px] font-extrabold tracking-wide text-white"
                  >
                    HOT
                  </div>
                </div>
              </div>
            </div>

            <!-- Info M -->
            <div class="flex flex-col gap-2.5 flex-1 min-w-0">
            <!-- Title Row M -->
            <h1 class="text-[26px] font-extrabold leading-none tracking-tight text-foreground">
              {{ series.title }}
            </h1>
            <p class="text-xs text-muted-foreground">
              {{ series.title }}
            </p>

            <!-- Author M -->
            <div class="flex items-center gap-2 text-xs">
              <div class="size-5 rounded-full bg-muted flex items-center justify-center border">
                <span class="text-[10px] font-bold text-muted-foreground">{{ authorDisplay().charAt(0).toUpperCase() }}</span>
              </div>
              <span class="font-semibold text-primary">{{ authorDisplay() }}</span>
              <span class="text-muted-foreground">• {{ new Date(series.insertedAt || Date.now()).getFullYear() }}</span>
            </div>

            <!-- Tags M -->
            <div v-if="categories.length > 0" class="flex flex-wrap gap-1.5">
              <a
                v-for="cat in categories"
                :key="cat.id"
                :href="`/series?category=${encodeURIComponent(cat.name)}`"
                class="rounded-full border bg-muted px-2.5 py-1 text-[10px] font-semibold text-muted-foreground hover:text-foreground hover:bg-accent transition-colors"
              >
                {{ cat.name }}
              </a>
              <span v-if="categories.length === 0" class="text-[10px] text-muted-foreground">No tags</span>
            </div>
            <div v-else class="flex flex-wrap gap-1.5">
              <span class="rounded-full border bg-muted px-2.5 py-1 text-[10px] font-semibold text-muted-foreground">Action</span>
              <span class="rounded-full border bg-muted px-2.5 py-1 text-[10px] font-semibold text-muted-foreground">Fantasy</span>
              <span class="rounded-full border bg-muted px-2.5 py-1 text-[10px] font-semibold text-muted-foreground">Isekai</span>
            </div>

            <!-- Stats Grid M -->
            <div class="rounded-xl border bg-muted/40 overflow-hidden">
              <div class="grid grid-cols-2">
                <div class="flex flex-col items-center gap-1 px-3 py-3 border-r">
                  <BookOpen class="size-3.5 text-muted-foreground" />
                  <span class="text-[9px] font-bold tracking-[1px] text-muted-foreground uppercase">Chapters</span>
                  <span class="text-base font-extrabold text-foreground">{{ stats.chapters }}</span>
                </div>
                <div class="flex flex-col items-center gap-1 px-3 py-3">
                  <Eye class="size-3.5 text-muted-foreground" />
                  <span class="text-[9px] font-bold tracking-[1px] text-muted-foreground uppercase">Views</span>
                  <span class="text-base font-extrabold text-foreground">{{ stats.views.toLocaleString() }}</span>
                </div>
              </div>
              <div class="grid grid-cols-2 border-t">
                <div class="flex flex-col items-center gap-1 px-3 py-3 border-r">
                  <Bookmark class="size-3.5 text-muted-foreground" />
                  <span class="text-[9px] font-bold tracking-[1px] text-muted-foreground uppercase">Bookmarked</span>
                  <span class="text-sm font-extrabold text-foreground">{{ localBookmarkCount.toLocaleString() }}</span>
                </div>
                <div class="flex flex-col items-center gap-1 px-3 py-3">
                  <Activity class="size-3.5 text-emerald-500" />
                  <span class="text-[9px] font-bold tracking-[1px] text-muted-foreground uppercase">Status</span>
                  <span class="text-sm font-extrabold" :class="statusClass">{{ statusLabel }}</span>
                </div>
              </div>
            </div>

            <!-- Update M -->
            <div class="flex items-center gap-1.5 text-[11px] text-muted-foreground">
              <Clock3 class="size-3" />
              <span>Last Update: {{ lastUpdateText }}</span>
            </div>

            <!-- Actions M -->
            <div class="flex flex-col gap-2">
              <div class="grid grid-cols-2 gap-2">
                <!-- Continue / First chapter — high contrast fix (feedback: grey bg + blue text hard to read) -->
                <a
                  v-if="latestChapter"
                  :href="`/series/${series.slug}/${latestChapter.chapterKey}`"
                  class="flex h-11 items-center justify-center gap-2 rounded-xl border bg-card text-card-foreground border-border shadow-sm hover:bg-accent hover:text-accent-foreground transition-colors"
                >
                  <BookOpen class="size-4 text-muted-foreground" />
                  <span class="flex flex-col items-center leading-none">
                    <span class="text-xs font-bold">Continue</span>
                    <span class="text-[10px] text-muted-foreground">{{ latestChapterLabel }}</span>
                  </span>
                </a>
                <div
                  v-else
                  class="flex h-11 items-center justify-center gap-2 rounded-xl border bg-muted text-muted-foreground"
                >
                  <BookOpen class="size-4" />
                  <span class="text-xs font-bold">No Chapter</span>
                </div>

                <!-- Latest -->
                <a
                  v-if="latestChapter"
                  :href="`/series/${series.slug}/${latestChapter.chapterKey}`"
                  class="flex h-11 items-center justify-center gap-2 rounded-xl bg-primary text-primary-foreground hover:bg-primary/90 transition-colors"
                >
                  <Sparkles class="size-4" />
                  <span class="flex flex-col items-center leading-none">
                    <span class="text-xs font-bold">Latest</span>
                    <span class="text-[10px] opacity-80">{{ latestChapterLabel }}</span>
                  </span>
                </a>
                <button
                  v-else
                  disabled
                  class="flex h-11 items-center justify-center gap-2 rounded-xl bg-primary/50 text-primary-foreground"
                >
                  <Sparkles class="size-4" />
                  <span class="text-xs font-bold">Latest</span>
                </button>
              </div>

              <!-- Bookmark row -->
              <button
                type="button"
                class="flex h-10 w-full items-center justify-center gap-2 rounded-xl border bg-card hover:bg-accent transition-colors"
                :class="localBookmarked ? 'border-primary bg-primary/10 text-primary' : 'border text-muted-foreground'"
                @click="toggleBookmark"
              >
                <Bookmark class="size-4" :class="localBookmarked ? 'fill-current' : ''" />
                <span class="text-xs font-semibold">
                  {{ localBookmarked ? 'Bookmarked' : 'Bookmark' }} • {{ currentUser ? '' : 'Login' }}
                </span>
                <span
                  v-if="!currentUser"
                  class="ml-1 flex size-5 items-center justify-center rounded-full bg-muted border"
                >
                  <Lock class="size-2.5" />
                </span>
                <span v-else class="text-[10px] text-muted-foreground">({{ localBookmarkCount }})</span>
              </button>
            </div>

            <!-- Rating Dist M -->
            <div class="rounded-xl border bg-card p-3.5 flex gap-3">
              <div class="flex w-[90px] flex-col items-center justify-center gap-1">
                <span class="text-[40px] font-extrabold leading-none text-amber-500">{{ averageDisplay }}</span>
                <div class="flex items-center gap-0.5">
                  <template v-for="i in 5" :key="i">
                    <Star
                      v-if="localRatingSummary.average != null && i <= Math.floor(localRatingSummary.average)"
                      class="size-3 fill-amber-400 text-amber-400"
                    />
                    <StarHalf
                      v-else-if="localRatingSummary.average != null && i - 0.5 <= localRatingSummary.average"
                      class="size-3 fill-amber-400 text-amber-400"
                    />
                    <Star v-else class="size-3 text-muted-foreground/30" />
                  </template>
                </div>
                <span class="text-[10px] text-muted-foreground">{{ votesText }}</span>
              </div>
              <div class="flex-1 flex flex-col gap-1.5 justify-center">
                <div v-for="row in displayDistribution" :key="row.rating" class="flex items-center gap-1.5">
                  <span class="w-3 text-[10px] font-bold">{{ row.rating }}</span>
                  <Star class="size-2.5 text-muted-foreground" />
                  <div class="flex-1 h-1.5 rounded-full bg-muted overflow-hidden">
                    <div
                      class="h-full bg-sky-500 rounded-full transition-all"
                      :style="{ width: `${row.percent}%` }"
                    />
                  </div>
                  <span class="w-9 text-right text-[10px] text-muted-foreground">{{ row.percent.toFixed(1) }}%</span>
                </div>
              </div>
            </div>

            <!-- Rate Input Inline — half-star support (feedback #3) -->
            <div class="rounded-xl border bg-card p-3 flex flex-col gap-2 items-center overflow-visible">
              <span class="text-[11px] font-semibold text-muted-foreground">Tap a star to rate (half star with left side)</span>
              <div class="flex w-full items-center justify-between gap-2">
                <div class="w-7 hidden sm:block" />
                <div class="flex items-center gap-1">
                  <button
                    v-for="n in 5"
                    :key="n"
                    type="button"
                    class="size-9 rounded-lg border flex items-center justify-center transition-colors relative overflow-hidden disabled:opacity-50 disabled:cursor-not-allowed"
                    :class="displayRating >= n ? 'bg-amber-100 border-amber-200 dark:bg-amber-900/30 dark:border-amber-800' : displayRating >= n - 0.5 ? 'bg-amber-50 border-amber-200 dark:bg-amber-900/20' : 'bg-card border-muted hover:bg-muted'"
                    :aria-label="`Rate ${n} stars`"
                    :disabled="ratingPending"
                    @mousemove="setHover($event, n)"
                    @mouseleave="clearHover"
                    @click="handleStarClick($event, n)"
                  >
                    <Star
                      v-if="displayRating >= n"
                      class="size-4 fill-amber-500 text-amber-500"
                    />
                    <StarHalf
                      v-else-if="displayRating >= n - 0.5"
                      class="size-4 fill-amber-500 text-amber-500"
                    />
                    <Star v-else class="size-4 text-muted-foreground" />
                  </button>
                </div>
                <div class="relative" ref="ellipsisRef">
                  <button
                    type="button"
                    class="size-7 rounded-lg border bg-card flex items-center justify-center hover:bg-accent"
                    aria-label="More actions"
                    @click="toggleRateMenu"
                  >
                    <EllipsisVertical class="size-4 text-muted-foreground" />
                  </button>
                  <!-- Dropdown — absolute with overflow-visible parent (feedback #1) -->
                  <div
                    v-if="showRateMenu"
                    data-rate-dropdown
                    class="absolute right-0 top-9 z-50 w-36 rounded-xl border bg-card shadow-xl overflow-hidden"
                    @click.stop
                  >
                    <button
                      type="button"
                      class="flex w-full items-center gap-2 px-3 py-2.5 text-xs hover:bg-accent text-left"
                      @click="handleShare"
                    >
                      <Share2 class="size-3.5 text-muted-foreground" />
                      <span>Share</span>
                    </button>
                    <Separator />
                    <button
                      type="button"
                      class="flex w-full items-center gap-2 px-3 py-2.5 text-xs hover:bg-accent text-left text-red-500"
                      @click="handleReport"
                    >
                      <Flag class="size-3.5" />
                      <span>Report</span>
                    </button>
                    <button
                      v-if="localUserRating"
                      type="button"
                      class="flex w-full items-center gap-2 px-3 py-2.5 text-xs hover:bg-accent text-left border-t"
                      @click="unrate(); showRateMenu = false"
                    >
                      <span>Clear rating</span>
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Desc Card M -->
      <div class="mt-3.5 rounded-xl border bg-card p-3.5 flex flex-col gap-2.5">
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2">
            <div class="h-3.5 w-0.5 rounded-full bg-primary" />
            <span class="text-xs font-extrabold">Description</span>
          </div>
          <button
            v-if="isLongDescription"
            type="button"
            class="flex items-center gap-1 rounded-lg bg-muted px-2 py-1 text-[10px] font-semibold text-muted-foreground hover:bg-accent"
            @click="expanded = !expanded"
          >
            {{ expanded ? 'Show less' : 'Show more' }}
            <ChevronDown class="size-3 transition-transform" :class="expanded ? 'rotate-180' : ''" />
          </button>
        </div>
        <Separator />
        <p class="text-xs leading-5 text-muted-foreground whitespace-pre-wrap break-words">
          {{ displayDescription }}
        </p>
      </div>

      <!-- Chapters Card M -->
      <div class="mt-3.5 rounded-xl border bg-card overflow-hidden">
        <div class="flex items-center justify-between px-3.5 py-3 border-b">
          <div class="flex items-center gap-2">
            <h2 class="text-sm font-extrabold">Chapters</h2>
            <span class="inline-flex items-center justify-center rounded-full bg-primary text-primary-foreground px-2.5 py-0.5 text-[11px] font-bold leading-none min-w-[22px] text-center shadow-sm">
              {{ chapterPagination.totalEntries }}
            </span>
          </div>
          <button
            type="button"
            class="flex items-center gap-1 rounded-md border px-2 py-1 text-xs hover:bg-accent"
            @click="toggleChapterSort"
          >
            <span>{{ chapterSort === 'newest' ? 'Newest' : 'Oldest' }}</span>
            <ChevronDown class="size-3" :class="chapterSort === 'newest' ? '' : 'rotate-180'" />
          </button>
        </div>

        <!-- Search -->
        <div class="px-3.5 py-2 border-b bg-muted/30">
          <div class="relative">
            <Search class="absolute left-2.5 top-1/2 -translate-y-1/2 size-3.5 text-muted-foreground" />
            <Input
              v-model="chapterQuery"
              placeholder="Search chapter..."
              class="h-8 pl-8 text-xs rounded-lg bg-card"
            />
          </div>
        </div>

        <div v-if="chaptersForList.length === 0" class="flex flex-col items-center gap-2.5 px-4 py-8">
          <div class="size-12 rounded-xl bg-muted flex items-center justify-center border">
            <BookOpen class="size-5 text-muted-foreground" />
          </div>
          <p class="text-sm font-bold">No chapters available</p>
          <p class="text-center text-xs text-muted-foreground max-w-[300px] leading-4">
            This series hasn't published any chapters yet. Follow to get notified.
          </p>
          <Button variant="outline" size="sm" class="h-8 gap-1.5 rounded-xl text-xs" @click="toggleBookmark">
            <Bell class="size-3" />
            Notify me
          </Button>
        </div>

        <div v-else class="divide-y">
          <a
            v-for="ch in chaptersForList"
            :key="ch.id"
            :href="`/series/${series.slug}/${ch.chapterKey}`"
            class="flex items-center justify-between px-3.5 py-3 hover:bg-muted/50 transition-colors"
          >
            <span class="flex flex-col gap-0.5">
              <span class="text-sm font-medium">Chapter {{ ch.displayNumber }}</span>
              <span v-if="ch.title" class="text-xs text-muted-foreground line-clamp-1">{{ ch.title }}</span>
            </span>
            <span class="text-[11px] text-muted-foreground">{{ formatChapterDate(ch.publishedAt) }}</span>
          </a>
        </div>

        <!-- Pagination -->
        <div
          v-if="chapterPagination.totalPages > 1"
          class="flex items-center justify-between px-3.5 py-3 border-t bg-muted/20"
        >
          <Button
            variant="ghost"
            size="sm"
            :disabled="!chapterPagination.hasPrevious"
            class="h-7 text-xs"
            @click="goChapterPage(chapterPagination.page - 1)"
          >
            Previous
          </Button>
          <span class="text-xs text-muted-foreground">
            Page {{ chapterPagination.page }} of {{ chapterPagination.totalPages }}
          </span>
          <Button
            variant="ghost"
            size="sm"
            :disabled="!chapterPagination.hasNext"
            class="h-7 text-xs"
            @click="goChapterPage(chapterPagination.page + 1)"
          >
            Next
          </Button>
        </div>
      </div>

      <!-- Comments Card M -->
      <div class="mt-3.5 rounded-xl border bg-card overflow-hidden">
        <div class="flex items-center justify-between px-3.5 py-3 border-b">
          <div class="flex items-center gap-2">
            <h2 class="text-sm font-extrabold">Comments</h2>
            <span class="rounded-md bg-muted px-1.5 py-0.5 text-[10px] font-bold text-muted-foreground">
              {{ commentCount }}
            </span>
          </div>
        </div>

        <!-- Threaded Comments recursive tree -->
        <CommentTree
          :tree="commentTreeNodes"
          :pagination="commentPagination"
          :sort="commentSort"
          :count="commentCount"
          :current-user="currentUser"
          :thread-id="threadId"
          :is-thread-view="isThreadView"
        />
      </div>

      <!-- Footer M -->
      <div class="mt-4 rounded-xl border bg-card px-3 py-3 text-center">
        <p class="text-[10px] text-muted-foreground">© 2025 Crysa • Terms • Privacy</p>
      </div>
    </div>
  </div>
  </div>
</template>
