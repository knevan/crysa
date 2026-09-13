<script setup lang="ts">
import { computed } from 'vue'
import type { BrowsePagination } from '@/assets/vue/catalog/browseTypes'

const props = defineProps<{ pagination: BrowsePagination }>()

const emit = defineEmits<{ page: [page: number] }>()

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

function goToPage(page: number) {
  const target = Math.min(Math.max(Math.floor(page) || 1, 1), totalPages.value)
  if (target !== currentPage.value) emit('page', target)
}

const segBase =
  'flex h-9 w-10 items-center justify-center border-y border-r border-[#E2E8F0] dark:border-zinc-800 text-sm transition-colors'
</script>

<template>
  <nav
    v-if="totalPages > 1"
    class="flex w-full items-center justify-center"
    aria-label="Browse pages"
  >
    <button
      type="button"
      aria-label="Previous page"
      :disabled="!props.pagination.hasPrevious"
      class="flex h-9 w-10 items-center justify-center rounded-l-lg border border-[#E2E8F0] dark:border-zinc-800 bg-[#F8FAFC] dark:bg-muted text-sm text-[#94A3B8] dark:text-zinc-500 transition-colors hover:bg-white dark:hover:bg-card disabled:cursor-not-allowed disabled:opacity-50"
      @click="goToPage(currentPage - 1)"
    >
      «
    </button>
    <template v-for="(item, i) in pageWindow" :key="item === '…' ? `gap-${i}` : item">
      <span
        v-if="item === '…'"
        class="flex h-9 w-11 items-center justify-center border-y border-r border-[#E2E8F0] dark:border-zinc-800 bg-white dark:bg-card text-sm text-[#94A3B8] dark:text-zinc-500"
      >
        …
      </span>
      <button
        v-else
        type="button"
        :aria-label="`Page ${item}`"
        :aria-current="item === currentPage ? 'page' : undefined"
        :class="[
          segBase,
          item === currentPage
            ? 'border-[#0F172A] bg-[#0F172A] font-bold text-white dark:border-zinc-100 dark:bg-zinc-100 dark:text-zinc-900'
            : 'bg-white dark:bg-card text-[#0F172A] dark:text-zinc-100 hover:bg-[#F8F9FB] dark:hover:bg-muted',
        ]"
        @click="goToPage(item)"
      >
        {{ item }}
      </button>
    </template>
    <button
      type="button"
      aria-label="Next page"
      :disabled="!props.pagination.hasNext"
      class="flex h-9 w-10 items-center justify-center rounded-r-lg border border-[#E2E8F0] dark:border-zinc-800 bg-white dark:bg-card text-sm text-[#0F172A] dark:text-zinc-100 transition-colors hover:bg-[#F8F9FB] dark:hover:bg-muted disabled:cursor-not-allowed disabled:opacity-50"
      @click="goToPage(currentPage + 1)"
    >
      »
    </button>
  </nav>
</template>
