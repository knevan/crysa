<script setup lang="ts">
import { computed, shallowRef } from 'vue'
import TrendingCarousel from '@/assets/vue/trending/TrendingCarousel.vue'
import { TRENDING_PERIODS, type TrendingLists, type TrendingPeriod } from '@/assets/vue/trending/types'

const props = defineProps<{
  initialPeriod: string
  lists: TrendingLists
}>()

const TAB_LABELS: Record<TrendingPeriod, string> = {
  hour: 'Hour',
  day: 'Today',
  week: 'This Week',
  month: 'This Month',
}

const SECTION_TITLES: Record<TrendingPeriod, string> = {
  hour: 'Trending This Hour',
  day: 'Trending Today',
  week: 'Trending This Week',
  month: 'Trending This Month',
}

function normalizePeriod(value: string): TrendingPeriod {
  return (TRENDING_PERIODS as string[]).includes(value) ? (value as TrendingPeriod) : 'day'
}

// Tab switches are client-side: all four lists arrive in one SSR payload, 
// so switching never triggers a fetch or skeleton.
const activePeriod = shallowRef<TrendingPeriod>(normalizePeriod(props.initialPeriod))

const currentItems = computed(() => props.lists[activePeriod.value]?.items ?? [])
const sectionTitle = computed(() => SECTION_TITLES[activePeriod.value])
</script>

<template>
  <div class="space-y-4">
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div class="flex items-center gap-3">
        <span>
          <h2 class="text-lg font-bold sm:text-xl">{{ sectionTitle }}</h2>
          <p class="hidden text-sm text-base-content/60 sm:block">What everyone is reading right now</p>
        </span>
      </div>
      <div role="tablist" aria-label="Trending period" class="ml-auto flex items-center gap-1 rounded-full bg-base-200 p-1">
        <button
          v-for="period in TRENDING_PERIODS"
          :key="period"
          type="button"
          role="tab"
          :aria-selected="activePeriod === period"
          :class="[
            'rounded-full px-3 py-1 text-xs font-semibold transition-colors sm:text-sm',
            activePeriod === period
              ? 'bg-indigo-600 text-white shadow'
              : 'text-base-content/60 hover:bg-base-300',
          ]"
          @click="activePeriod = period"
        >
          {{ TAB_LABELS[period] }}
        </button>
      </div>
    </div>
    <TrendingCarousel :items="currentItems" />
  </div>
</template>
