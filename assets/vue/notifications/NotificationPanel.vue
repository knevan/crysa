<script setup lang="ts">
import { computed, onMounted, ref, useTemplateRef, watch } from 'vue'
import { useLiveVue, Link } from 'live_vue'
import { Bell, BookMarked, Check, ChevronLeft, ChevronRight, MessageCircle, ThumbsUp, ThumbsDown, X } from '@lucide/vue'
import { Button } from '@/assets/vue/components/ui/button'

type Actor = { id: number; username: string }
type SeriesRef = { id: number; title: string; slug: string; cover_url: string | null }
type ChapterRef = { id: number; chapter_key: string; display_number: string; title: string | null }
type CommentRef = {
  id: number
  excerpt: string
  series_id: number | null
  series_slug: string | null
  chapter_id: number | null
}

type NotificationItem = {
  id: number
  action: string
  read_at: string | null
  inserted_at: string
  actor: Actor | null
  series: SeriesRef | null
  chapter: ChapterRef | null
  comment: CommentRef | null
}

type UnreadCounts = { comment: number; series: number; total: number }

const props = withDefaults(
  defineProps<{
    items: NotificationItem[]
    hasMore: boolean
    cursor: number | null
    activeTab: string
    unread: UnreadCounts
    currentUser: { id: number; username: string } | null
    showViewAll?: boolean
    showLoadMore?: boolean
    page?: number
    totalPages?: number
  }>(),
  { showViewAll: true, showLoadMore: true, page: 1, totalPages: 1 },
)

const live = useLiveVue()

const rows = computed(() => props.items ?? [])
// Full page (showViewAll false) renders borderless on the page background;
// the dropdown keeps its floating card.
const isPage = computed(() => !props.showViewAll)
const tabUnread = computed(() =>
  props.activeTab === 'series' ? (props.unread?.series ?? 0) : (props.unread?.comment ?? 0),
)
const totalUnread = computed(() => props.unread?.total ?? 0)

function relativeTime(iso: string): string {
  const diffMs = Date.now() - new Date(iso).getTime()
  const minutes = Math.max(0, Math.floor(diffMs / 60_000))
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.floor(hours / 24)
  if (days < 30) return `${days}d ago`
  const months = Math.floor(days / 30)
  if (months < 12) return `${months}mo ago`
  return `${Math.floor(months / 12)}y ago`
}

function rowTitle(item: NotificationItem): string {
  const actor = item.actor?.username ?? 'Someone'
  switch (item.action) {
    case 'series_chapter':
      return item.series?.title ?? 'New chapter'
    case 'comment_reply':
      return `${actor} replied to your comment`
    case 'comment_upvote':
      return `${actor} upvoted your comment`
    case 'comment_downvote':
      return `${actor} downvoted your comment`
    default:
      return 'Notification'
  }
}

function rowMeta(item: NotificationItem): string {
  const time = relativeTime(item.inserted_at)
  if (item.action === 'series_chapter' && item.chapter) {
    return `${time} · Ch.${item.chapter.display_number}`
  }
  if (item.comment?.excerpt) {
    return `${time} · ${item.comment.excerpt}`
  }
  return time
}

// Deep link: chapter reader for series updates, thread view for comments.
function rowHref(item: NotificationItem): string | null {
  if (item.action === 'series_chapter' && item.series && item.chapter) {
    return `/series/${item.series.slug}/${item.chapter.chapter_key}`
  }
  if (item.comment?.series_slug) {
    return `/series/${item.comment.series_slug}?thread=${item.comment.id}`
  }
  return null
}

function switchTab(tab: string) {
  if (tab !== props.activeTab) {
    live.pushEvent('notifications_tab', { tab })
  }
}

// --- Numbered pagination (full page only) ---------------------------------
// The dropdown caps at its preview window (showLoadMore false) and never
// sees this; the page replaces its list per page instead of appending.
const totalPageCount = computed(() => Math.max(1, Math.floor(props.totalPages ?? 1)))
const currentPage = computed(() => {
  const raw = Math.floor(Number(props.page) || 1)
  return Math.min(Math.max(raw, 1), totalPageCount.value)
})

// Compact window: all pages when few, otherwise first/last with ellipsis
// around the current page.
const pageWindow = computed<(number | '…')[]>(() => {
  const total = totalPageCount.value
  const current = currentPage.value
  if (total <= 7) return Array.from({ length: total }, (_, i) => i + 1)
  const inner = new Set([1, total, current - 1, current, current + 1])
  const pages = [...inner].filter((p) => p >= 1 && p <= total).sort((a, b) => a - b)
  const window: (number | '…')[] = []
  let prev = 0
  for (const p of pages) {
    if (p - prev > 1) window.push('…')
    window.push(p)
    prev = p
  }
  return window
})

function goToPage(page: number) {
  const target = Math.min(Math.max(Math.floor(page) || 1, 1), totalPageCount.value)
  if (target !== currentPage.value) {
    live.pushEvent('notifications_page', { page: target })
  }
}

function markItemRead(id: number) {
  live.pushEvent('notifications_mark_read', { scope: 'item', id })
}

function markTabRead() {
  live.pushEvent('notifications_mark_read', { scope: 'tab' })
}

// Island-mount safety net: the dropdown opens instantly client-side,
// so a toggle made before connect (or across a reconnect) never reaches
// the server. When this island mounts while actually visible, report it;
// the server loads the feed idempotently. Hidden ancestors make
// offsetParent null, so invisible mounts stay silent and lazy.
const panelRoot = useTemplateRef<HTMLDivElement>('panelRoot')
onMounted(() => {
  if (panelRoot.value && panelRoot.value.offsetParent !== null) {
    live.pushEvent('notifications_opened', {})
  }
})

// After a page jump the user sits at the bottom of the old list;
// bring the panel back into view once the new rows arrive.
watch(currentPage, () => {
  panelRoot.value?.scrollIntoView({ block: 'start' })
})

// --- Swipe to read (touch) -------------------------------------------------
// Horizontal left swipe marks a row read.
// Vertical gestures are left to native scroll via `touch-pan-y`.
// Taps (no significant movement) fall through to the row link.
const swipeOffset = ref<Record<number, number>>({})
const swipingId = ref<number | null>(null)
let touchStartX = 0
let touchStartY = 0
let suppressClickUntil = 0

const swipeThreshold = 70
const swipeMax = 140

function onTouchStart(e: TouchEvent, id: number) {
  const touch = e.touches[0]
  if (!touch) return
  // Clear interrupted swipe on another row before taking over.
  if (swipingId.value !== null && swipingId.value !== id) {
    swipeOffset.value[swipingId.value] = 0
  }
  touchStartX = touch.clientX
  touchStartY = touch.clientY
  swipingId.value = id
  if (!(id in swipeOffset.value)) swipeOffset.value[id] = 0
}

function onTouchMove(e: TouchEvent, id: number) {
  if (swipingId.value !== id) return
  const touch = e.touches[0]
  if (!touch) return
  const dx = touch.clientX - touchStartX
  const dy = touch.clientY - touchStartY
  // Let vertical scroll win over short horizontal drift.
  if (Math.abs(dy) > Math.abs(dx)) return
  if (dx < 0) {
    swipeOffset.value[id] = Math.max(dx, -swipeMax)
  }
}

function onTouchEnd(id: number) {
  if (swipingId.value !== id) return
  swipingId.value = null
  const dx = swipeOffset.value[id] ?? 0
  if (dx <= -swipeThreshold) {
    // A real swipe, not a tap: swallow the following click and mark read.
    suppressClickUntil = Date.now() + 400
    swipeOffset.value[id] = -swipeMax
    markItemRead(id)
    // Slide back after feedback; guard avoids killing a new swipe.
    setTimeout(() => {
      if (swipingId.value !== id && swipeOffset.value[id] === -swipeMax) {
        swipeOffset.value[id] = 0
      }
    }, 300)
  } else {
    swipeOffset.value[id] = 0
  }
}

function onTouchCancel(id: number) {
  if (swipingId.value === id) swipingId.value = null
  swipeOffset.value[id] = 0
}

function guardSwipeClick(e: Event) {
  if (Date.now() < suppressClickUntil) {
    e.preventDefault()
    e.stopPropagation()
  }
}

// Prune offsets for rows that left the list (dropdown removes on read);
// reset stuck offsets for rows kept as history (full page stamps read_at).
watch(
  () => props.items.map((item) => `${item.id}:${item.read_at ?? ''}`),
  () => {
    const alive = new Set(props.items.map((item) => item.id))
    for (const key of Object.keys(swipeOffset.value)) {
      if (!alive.has(Number(key))) delete swipeOffset.value[Number(key)]
    }
    for (const item of props.items) {
      if (item.read_at != null && swipingId.value !== item.id) {
        if ((swipeOffset.value[item.id] ?? 0) !== 0) swipeOffset.value[item.id] = 0
      }
    }
  },
)
</script>

<template>
  <div
    ref="panelRoot"
    :class="
      isPage
        ? 'bg-transparent text-card-foreground'
        : 'rounded-sm bg-muted text-card-foreground shadow-xl'
    "
  >
    <!-- Panel header -->
    <div class="flex items-start justify-between gap-3 p-4 pb-3">
      <div>
        <p class="text-[11px] font-extrabold tracking-[0.12em] text-muted-foreground">NOTIFICATIONS</p>
        <p class="mt-0.5 text-sm text-muted-foreground">
          {{ totalUnread > 0 ? `${totalUnread} unread` : 'All caught up' }}
        </p>
      </div>
      <div>
        <Button
          variant="ghost"
          size="sm"
          class="gap-1.5 text-muted-foreground"
          :disabled="tabUnread === 0"
          :title="tabUnread === 0 ? 'Nothing to mark as read' : `Mark all ${activeTab} as read`"
          @click="markTabRead"
        >
          <Check class="size-3.5" />
          Mark as read
        </Button>
      </div>
    </div>

    <!-- Tabs -->
    <div class="flex gap-2 px-4 pb-3">
      <Button
        :variant="activeTab === 'series' ? 'default' : 'secondary'"
        size="sm"
        class="gap-2 rounded-[10px]"
        @click="switchTab('series')"
      >
        Series
        <span
          class="rounded-md px-1.5 py-0.5 text-[10px] font-extrabold"
          :class="activeTab === 'series' ? 'bg-primary-foreground/20 text-primary-foreground' : 'bg-muted text-muted-foreground'"
        >
          {{ unread.series }}
        </span>
      </Button>
      <Button
        :variant="activeTab === 'comment' ? 'default' : 'secondary'"
        size="sm"
        class="gap-2 rounded-[10px]"
        @click="switchTab('comment')"
      >
        Comment
        <span
          class="rounded-md px-1.5 py-0.5 text-[10px] font-extrabold"
          :class="activeTab === 'comment' ? 'bg-primary-foreground/20 text-primary-foreground' : 'bg-muted text-muted-foreground'"
        >
          {{ unread.comment }}
        </span>
      </Button>
    </div>

    <!-- Rows -->
    <div v-if="rows.length > 0" class="flex flex-col gap-2">
      <div
        v-for="item in rows"
        :key="item.id"
        class="relative overflow-hidden rounded-xl"
        @click.capture="guardSwipeClick"
      >
        <!-- Swipe-to-read backdrop, revealed by left swipe (unread only) -->
        <div
          v-if="item.read_at == null"
          class="absolute inset-y-0 right-0 flex w-24 items-center justify-center bg-red-500/15"
        >
          <X class="size-5 text-red-600 dark:text-red-400" />
        </div>
        <div
          class="relative flex items-center gap-3 px-4 py-3 touch-pan-y select-none"
          :class="[
            { 'transition-transform duration-200 ease-out': swipingId !== item.id },
            item.read_at == null ? 'bg-card' : 'bg-muted',
          ]"
          :style="{ transform: `translateX(${swipeOffset[item.id] ?? 0}px)` }"
          @touchstart="(e) => item.read_at == null && onTouchStart(e, item.id)"
          @touchmove="(e) => item.read_at == null && onTouchMove(e, item.id)"
          @touchend="() => item.read_at == null && onTouchEnd(item.id)"
          @touchcancel="() => onTouchCancel(item.id)"
        >
          <!-- Unread accent bar (left edge), inspired by reference; moves with the row -->
          <span
            v-if="item.read_at == null"
            class="absolute bottom-0 left-0 top-0 w-0.75 bg-sky-400"
            aria-hidden="true"
          />
          <div
            class="flex size-8.5 shrink-0 items-center justify-center rounded-full"
            :class="item.read_at == null ? 'bg-primary/10' : 'bg-muted'"
          >
            <BookMarked
              v-if="item.action === 'series_chapter'"
              class="size-4"
              :class="item.read_at == null ? 'text-primary' : 'text-muted-foreground'"
            />
            <MessageCircle
              v-else-if="item.action === 'comment_reply'"
              class="size-4"
              :class="item.read_at == null ? 'text-primary' : 'text-muted-foreground'"
            />
            <ThumbsUp
              v-else-if="item.action === 'comment_upvote'"
              class="size-4"
              :class="item.read_at == null ? 'text-primary' : 'text-muted-foreground'"
            />
            <ThumbsDown
              v-else-if="item.action === 'comment_downvote'"
              class="size-4"
              :class="item.read_at == null ? 'text-primary' : 'text-muted-foreground'"
            />
            <Bell
              v-else
              class="size-4"
              :class="item.read_at == null ? 'text-primary' : 'text-muted-foreground'"
            />
          </div>
          <div class="min-w-0 flex-1">
            <component
              :is="rowHref(item) ? Link : 'span'"
              v-bind="rowHref(item) ? { href: rowHref(item) } : {}"
              class="block line-clamp-2 text-[15px] leading-snug hover:underline"
              :class="item.read_at == null ? 'font-bold text-foreground' : 'font-semibold text-muted-foreground'"
            >
              {{ rowTitle(item) }}
            </component>
            <p class="truncate text-xs text-muted-foreground">{{ rowMeta(item) }}</p>
          </div>
          <img
            v-if="item.series?.cover_url"
            :src="item.series.cover_url"
            :alt="item.series.title"
            class="h-13 w-10 shrink-0 rounded-lg object-cover"
            loading="lazy"
          />
          <button
            v-if="item.read_at == null"
            type="button"
            title="Mark as read"
            aria-label="Mark as read"
            class="hidden shrink-0 items-center justify-center rounded-full p-1.5 text-muted-foreground hover:bg-muted hover:text-foreground pointer-fine:inline-flex"
            @click="markItemRead(item.id)"
          >
            <Check class="size-4" />
          </button>
        </div>
      </div>
    </div>

    <!-- Empty state -->
    <div v-else class="flex flex-col items-center gap-2 px-4 py-10 text-center">
      <div class="flex size-10 items-center justify-center rounded-full bg-muted">
        <Bell class="size-4 text-muted-foreground" />
      </div>
      <p class="text-sm font-semibold">No notifications yet</p>
      <p class="max-w-60 text-xs text-muted-foreground">
        {{
          activeTab === 'series'
            ? 'New chapters from your bookmarked series will appear here.'
            : 'Replies and votes on your comments will appear here.'
        }}
      </p>
    </div>

    <!-- Pagination (full page only; the dropdown caps at its preview window) -->
    <nav
      v-if="showLoadMore && totalPageCount > 1"
      class="flex items-center justify-center gap-1 p-3"
      aria-label="Notifications pages"
    >
      <Button
        variant="ghost"
        size="sm"
        class="gap-1"
        :disabled="currentPage <= 1"
        aria-label="Previous page"
        @click="goToPage(currentPage - 1)"
      >
        <ChevronLeft class="size-3.5" />
        Prev
      </Button>
      <template v-for="(entry, i) in pageWindow" :key="entry === '…' ? `gap-${i}` : entry">
        <span v-if="entry === '…'" class="px-1 text-xs text-muted-foreground">…</span>
        <Button
          v-else
          :variant="entry === currentPage ? 'default' : 'ghost'"
          size="sm"
          class="min-w-8"
          :aria-label="`Page ${entry}`"
          :aria-current="entry === currentPage ? 'page' : undefined"
          @click="goToPage(entry)"
        >
          {{ entry }}
        </Button>
      </template>
      <Button
        variant="ghost"
        size="sm"
        class="gap-1"
        :disabled="currentPage >= totalPageCount"
        aria-label="Next page"
        @click="goToPage(currentPage + 1)"
      >
        Next
        <ChevronRight class="size-3.5" />
      </Button>
    </nav>

    <!-- View-all footer (dropdown only; the page itself is the view-all) -->
    <div v-if="showViewAll" class="p-3">
      <Link
        href="/notifications"
        class="flex w-full items-center justify-center gap-1 rounded-md bg-muted px-3 py-2 text-xs font-semibold text-muted-foreground hover:text-foreground"
      >
        View all notifications
        <ChevronRight class="size-3.5" />
      </Link>
    </div>
  </div>
</template>
