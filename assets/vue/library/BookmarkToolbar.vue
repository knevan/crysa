<script setup lang="ts">
import { computed } from 'vue'
import BookmarkSelect, { type SelectOption } from '@/assets/vue/library/BookmarkSelect.vue'

export type BookmarkStatus = 'all' | 'ongoing' | 'completed' | 'hiatus' | 'discontinued'
export type BookmarkSort = 'latest_update' | 'bookmarked_at' | 'title'
export type BookmarkOrder = 'asc' | 'desc'

const props = defineProps<{
  status: string
  sortBy: string
  order: string
}>()

const emit = defineEmits<{
  filter: [payload: { status: string; sortBy: string; order: string }]
  download: []
}>()

const statusModel = computed({
  get: () => props.status,
  set: (v: string) => emit('filter', { status: v, sortBy: props.sortBy, order: props.order }),
})

const sortModel = computed({
  get: () => props.sortBy,
  set: (v: string) => emit('filter', { status: props.status, sortBy: v, order: props.order }),
})

const orderModel = computed({
  get: () => props.order,
  set: (v: string) => emit('filter', { status: props.status, sortBy: props.sortBy, order: v }),
})

const statusOptions: SelectOption[] = [
  { value: 'all', label: 'Status: All' },
  { value: 'ongoing', label: 'Status: Ongoing' },
  { value: 'completed', label: 'Status: Completed' },
  { value: 'hiatus', label: 'Status: Hiatus' },
  { value: 'discontinued', label: 'Status: Discontinued' },
]

const sortOptions: SelectOption[] = [
  { value: 'latest_update', label: 'Latest Update' },
  { value: 'bookmarked_at', label: 'Recently Added' },
  { value: 'title', label: 'Title' },
]

const orderOptions: SelectOption[] = [
  { value: 'desc', label: 'Desc' },
  { value: 'asc', label: 'Asc' },
]
</script>

<template>
  <!-- Toolbar / Sort Group. -->
  <!-- Desktop: right-aligned row. Mobile: stacked (sort row, status row, download). -->
  <div class="flex w-full flex-col gap-3 md:flex-row md:items-center md:justify-end">
    <button
      type="button"
      class="order-3 h-10.5 w-full rounded-md bg-[#6D28D9] px-5 text-[13px] font-bold text-white transition-colors hover:bg-[#5B21B6] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[#6D28D9] focus-visible:ring-offset-2 md:order-1 md:w-auto md:py-2.25"
      @click="emit('download')"
    >
      Download
    </button>

    <div class="order-2 grid grid-cols-1 gap-3 md:order-2 md:flex md:items-center">
      <BookmarkSelect v-model="statusModel" :options="statusOptions" label="Filter by status" />
    </div>

    <div class="order-1 grid grid-cols-[1fr_88px] gap-3 md:order-3 md:flex md:items-center md:gap-3">
      <BookmarkSelect v-model="sortModel" :options="sortOptions" label="Sort by" />
      <div class="md:w-22">
        <BookmarkSelect v-model="orderModel" :options="orderOptions" label="Sort order" />
      </div>
    </div>
  </div>
</template>
