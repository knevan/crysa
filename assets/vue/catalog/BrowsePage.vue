<script setup lang="ts">
import { useTemplateRef, watch } from 'vue'
import { useLiveVue } from 'live_vue'
import { SearchX } from '@lucide/vue'
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
</script>

<template>
  <div class="min-h-screen bg-[#F8F9FB]">
    <div class="mx-auto flex w-full max-w-[960px] flex-col gap-5 px-6 pb-12 pt-8">
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
        <div v-if="props.entries.length > 0" class="grid w-full grid-cols-2 gap-4 md:grid-cols-3 lg:grid-cols-5">
          <BrowseSeriesCard v-for="entry in props.entries" :key="entry.id" :entry="entry" />
        </div>
        <div
          v-else
          class="flex w-full flex-col items-center gap-3 rounded-xl border border-[#E2E8F0] bg-white px-6 py-14 text-center"
        >
          <div class="flex size-12 items-center justify-center rounded-xl border border-[#E2E8F0] bg-[#F8F9FB]">
            <SearchX class="size-5 text-[#94A3B8]" />
          </div>
          <p class="text-sm font-bold text-[#0F172A]">No series match your filters.</p>
          <p class="max-w-[320px] text-xs leading-5 text-[#64748B]">
            Try a different search term or clear some genre filters.
          </p>
        </div>
      </div>

      <BrowsePagination
        :pagination="props.pagination"
        @page="(page) => live.pushEvent('browse_page', { page })"
      />

      <div class="border-t border-[#E2E8F0] bg-white py-5 text-center">
        <p class="hidden text-xs text-[#94A3B8] sm:block">
          © 2025 Crysa • Crafted for manga lovers • Terms • Privacy • DMCA
        </p>
        <p class="text-xs text-[#94A3B8] sm:hidden">© 2025 Crysa • Terms • Privacy</p>
      </div>
    </div>
  </div>
</template>
