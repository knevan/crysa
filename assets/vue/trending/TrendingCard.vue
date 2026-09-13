<script setup lang="ts">
import { computed } from 'vue'
import { Star } from '@lucide/vue'
import type { TrendingItem } from '@/assets/vue/trending/types'

const props = defineProps<{
  item: TrendingItem
  rank: number
}>()

const seriesHref = computed(() => `/series/${props.item.slug}`)

// Keep one decimal in UI even though backend already rounds.
const formattedRating = computed(() =>
  props.item.ratingAverage != null ? props.item.ratingAverage.toFixed(1) : null,
)

// Medal colors for the podium ranks; the rest keep a neutral dark badge.
const rankClasses = computed(() => {
  if (props.rank === 1) return 'bg-gradient-to-br from-yellow-200 to-amber-500 text-amber-950'
  if (props.rank === 2) return 'bg-gradient-to-br from-gray-100 to-gray-400 text-gray-900'
  if (props.rank === 3) return 'bg-gradient-to-br from-orange-300 to-amber-700 text-white'
  return 'bg-black/60 text-white'
})
</script>

<template>
  <div class="relative mr-3 min-w-0 grow-0 shrink-0 basis-[31%] sm:basis-[23%] lg:basis-[15.5%]">
    <a :href="seriesHref" class="group block" :aria-label="props.item.title">
      <div class="relative aspect-3/4 overflow-hidden rounded-lg bg-base-200 shadow-sm">
        <img
          :src="props.item.coverUrl || '/images/placeholder-cover.svg'"
          :alt="props.item.title"
          loading="lazy"
          decoding="async"
          draggable="false"
          @error="(e) => { const t = e.target as HTMLImageElement; t.onerror = null; t.src = '/images/placeholder-cover.svg' }"
          class="h-full w-full object-cover"
        />
        <span
          aria-hidden="true"
          :class="[
            'pointer-events-none absolute top-1 left-1 rounded-md px-1.5 py-0.5 text-xs font-bold shadow',
            rankClasses,
          ]"
        >
          {{ props.rank }}
        </span>
        <span
          v-if="formattedRating != null"
          aria-hidden="true"
          class="pointer-events-none absolute top-1 right-1 flex items-center gap-0.5 rounded-md bg-black/65 px-1.5 py-0.5 text-[11px] font-bold text-white shadow backdrop-blur-sm"
        >
          <Star class="size-3 fill-amber-400 text-amber-400" />
          {{ formattedRating }}
        </span>
        <span
          aria-hidden="true"
          class="pointer-events-none absolute right-1 bottom-1 rounded-md bg-black/65 px-1.5 py-0.5 text-[11px] font-semibold text-white tabular-nums shadow backdrop-blur-sm"
        >
          Ch. {{ props.item.chapterCount }}
        </span>
      </div>
      <h3
        class="mt-2 line-clamp-2 min-h-8 text-xs font-semibold text-base-content group-hover:text-primary"
      >
        {{ props.item.title }}
      </h3>
    </a>
  </div>
</template>
