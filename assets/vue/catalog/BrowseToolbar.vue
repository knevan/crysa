<script setup lang="ts">
import { ref, watch } from 'vue'
import { useDebounceFn } from '@vueuse/core'
import { Search } from '@lucide/vue'
import BrowseDropdown from '@/assets/vue/catalog/BrowseDropdown.vue'
import { SORT_OPTIONS, STATUS_OPTIONS } from '@/assets/vue/catalog/browseTypes'

const props = defineProps<{
  query: string
  sort: string
  pubStatus: string
}>()

const emit = defineEmits<{
  search: [q: string]
  sort: [sort: string]
  status: [status: string]
}>()

// Local search text so typing never waits for a server round-trip; the
// debounced watcher pushes the event, the server echoes back via props.
const searchText = ref(props.query || '')
watch(
  () => props.query,
  (next) => {
    if ((next || '') !== searchText.value) searchText.value = next || ''
  },
)

const debouncedSearch = useDebounceFn((value: string) => {
  emit('search', value.trim())
}, 350)

watch(searchText, (value) => debouncedSearch(value))
</script>

<template>
  <div class="flex w-full flex-col gap-3 md:flex-row md:items-center">
    <div class="relative flex-1">
      <Search class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-[#94A3B8] dark:text-zinc-500" />
      <input
        v-model="searchText"
        type="search"
        placeholder="Search by title..."
        aria-label="Search by title"
        class="h-10 w-full rounded-lg border border-[#E2E8F0] dark:border-zinc-800 bg-white dark:bg-card pl-9 pr-3 text-sm text-[#0F172A] dark:text-zinc-100 placeholder:text-[#94A3B8] dark:placeholder:text-zinc-500 focus:border-[#93C5FD] focus:outline-none focus:ring-2 focus:ring-[#93C5FD]/40"
      />
    </div>

    <div class="flex w-full flex-row gap-3 md:w-auto">
      <div class="min-w-0 flex-1 sm:flex-none">
        <BrowseDropdown
          :options="STATUS_OPTIONS"
          :value="props.pubStatus"
          label="Filter by publication status"
          variant="neutral"
          fallback-label="All"
          @pick="(v) => emit('status', v)"
        />
      </div>
      <div class="min-w-0 flex-1 sm:flex-none">
        <BrowseDropdown
          :options="SORT_OPTIONS"
          :value="props.sort"
          label="Sort series"
          variant="accent"
          fallback-label="Last Updated"
          @pick="(v) => emit('sort', v)"
        />
      </div>
    </div>
  </div>
</template>
