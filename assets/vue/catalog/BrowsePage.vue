<script setup lang="ts">
import { computed, useTemplateRef, watch } from 'vue'
import { useLiveVue } from 'live_vue'
import { ArrowDown, SearchX } from '@lucide/vue'
import BrowseFilterCard from '@/assets/vue/catalog/BrowseFilterCard.vue'
import BrowsePagination from '@/assets/vue/catalog/BrowsePagination.vue'
import BrowseSeriesCard from '@/assets/vue/catalog/BrowseSeriesCard.vue'
import BrowseToolbar from '@/assets/vue/catalog/BrowseToolbar.vue'
import type { BrowseCategory, BrowseEntry, BrowsePagination as Page } from '@/assets/vue/catalog/browseTypes'

const props = defineProps<{
  entries: BrowseEntry[]
  pagination: Page
  categories: BrowseCategory[]
  includeTags: string[]
  excludeTags: string[]
  query: string
  sort: string
  pubStatus: string
  pendingUpdates: number
}>()

const live = useLiveVue()
const resultsTop = useTemplateRef<HTMLDivElement>('resultsTop')

function scrollToResults() {
  resultsTop.value?.scrollIntoView({ block: 'start' })
}

watch(
  () => props.pagination.page,
  () => scrollToResults(),
)

// Bulk scrapes bump the counter fast; cap the label so the pill stays compact.
const pendingLabel = computed(() => {
  const n = props.pendingUpdates || 0
  if (n <= 0) return ''
  if (n === 1) return '1 new update'
  if (n > 20) return '20+ new updates'
  return `${n} new updates`
})
</script>

<template>
  <div class="min-h-screen bg-[#F8F9FB] dark:bg-background">
    <div class="mx-auto flex w-full max-w-240 flex-col gap-5 px-6 pb-12 pt-8">
      <BrowseFilterCard
        :categories="props.categories"
        :include-tags="props.includeTags"
        :exclude-tags="props.excludeTags"
        @toggle="(name) => live.pushEvent('browse_toggle_tag', { name })"
        @reset="() => live.pushEvent('browse_reset', {})"
        @apply="() => { live.pushEvent('browse_apply', {}); scrollToResults() }"
      />

      <div class="flex w-full justify-end">
        <BrowseToolbar
          :query="props.query"
          :sort="props.sort"
          :pub-status="props.pubStatus"
          @search="(q) => live.pushEvent('browse_search', { q })"
          @sort="(sort) => live.pushEvent('browse_sort', { sort })"
          @status="(status) => live.pushEvent('browse_status', { status })"
        />
      </div>

      <div ref="resultsTop" class="scroll-mt-4">
        <div v-if="pendingLabel" class="sticky top-3 z-20 mb-3 flex justify-center">
          <button
            type="button"
            role="status"
            aria-live="polite"
            aria-label="New updates available, refresh the list"
            class="flex items-center gap-2 rounded-full bg-[#0F172A] py-2 pl-4 pr-3 text-[13px] font-semibold text-white shadow-lg transition-colors hover:bg-[#1E293B] dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-white"
            @click="() => live.pushEvent('browse_refresh', {})"
          >
            <ArrowDown class="size-4 shrink-0" />
            {{ pendingLabel }}
            <span class="rounded-full bg-white/20 px-2.5 py-0.5 text-xs font-bold">Refresh</span>
          </button>
        </div>
        <div v-if="props.entries.length > 0" class="grid w-full grid-cols-2 gap-4 md:grid-cols-3 lg:grid-cols-5">
          <BrowseSeriesCard v-for="entry in props.entries" :key="entry.id" :entry="entry" />
        </div>
        <div
          v-else
          class="flex w-full flex-col items-center gap-3 rounded-xl border border-[#E2E8F0] dark:border-zinc-800 bg-white dark:bg-card px-6 py-14 text-center"
        >
          <div class="flex size-12 items-center justify-center rounded-xl border border-[#E2E8F0] dark:border-zinc-800 bg-[#F8F9FB] dark:bg-muted">
            <SearchX class="size-5 text-[#94A3B8] dark:text-zinc-500" />
          </div>
          <p class="text-sm font-bold text-[#0F172A] dark:text-zinc-100">No series match your filters.</p>
          <p class="max-w-[320px] text-xs leading-5 text-[#64748B] dark:text-zinc-400">
            Try a different search term or clear some genre filters.
          </p>
        </div>
      </div>

      <BrowsePagination
        :pagination="props.pagination"
        @page="(page) => live.pushEvent('browse_page', { page })"
      />

      <div class="border-t border-[#E2E8F0] dark:border-zinc-800 bg-white dark:bg-card py-5 text-center">
        <p class="hidden text-xs text-[#94A3B8] dark:text-zinc-500 sm:block">
          © 2025 Crysa • Crafted for manga lovers • Terms • Privacy • DMCA
        </p>
        <p class="text-xs text-[#94A3B8] dark:text-zinc-500 sm:hidden">© 2025 Crysa • Terms • Privacy</p>
      </div>
    </div>
  </div>
</template>
