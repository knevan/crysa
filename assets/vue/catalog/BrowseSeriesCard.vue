<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { View, Star } from '@lucide/vue'
import type { BrowseEntry } from '@/assets/vue/catalog/browseTypes'
import { formatViews, gradientStyle } from '@/assets/vue/catalog/browseFormat'

const props = defineProps<{ entry: BrowseEntry }>()

const seriesHref = computed(() => `/series/${props.entry.slug}`)

// Discovery intent: always start at chapter 1, never mid-story.
const readHref = computed(() =>
  props.entry.firstChapter
    ? `/series/${props.entry.slug}/${props.entry.firstChapter.chapterKey}`
    : seriesHref.value,
)

const views = computed(() => formatViews(props.entry.viewCount))
const coverStyle = computed(() => gradientStyle(props.entry.id))

// Brief highlight when a live view-count patch lands
// Layout never shifts and the grid never reorders.
const viewsFlash = ref(false)
let flashTimer: ReturnType<typeof setTimeout> | undefined
watch(views, () => {
  viewsFlash.value = true
  clearTimeout(flashTimer)
  flashTimer = setTimeout(() => (viewsFlash.value = false), 500)
})
</script>

<template>
  <article class="flex h-full min-w-0 flex-col gap-2">
    <div class="relative h-55 w-full overflow-hidden rounded-lg md:h-62.5">
      <a :href="seriesHref" class="block h-full w-full" :aria-label="entry.title">
        <img
          v-if="entry.coverUrl"
          :src="entry.coverUrl"
          :alt="entry.title"
          class="h-full w-full object-cover"
          loading="lazy"
          @error="(e) => ((e.target as HTMLImageElement).style.display = 'none')"
        />
        <div v-else class="h-full w-full" :style="coverStyle" />
      </a>
      <div
        v-if="entry.trending"
        class="absolute left-2 top-2 rounded-md bg-[#EF4444] px-2 py-0.75 text-[9px] font-extrabold tracking-[0.6px] text-white"
      >
        TRENDING
      </div>
    </div>

    <a
      :href="seriesHref"
      :title="entry.title"
      class="line-clamp-2 block min-h-10 w-full text-sm font-bold leading-5 text-[#0F172A] dark:text-zinc-100 hover:text-[#2563EB] dark:hover:text-blue-400"
    >
      {{ entry.title }}
    </a>

    <p class="line-clamp-2 min-h-10 w-full text-xs leading-5 text-[#64748B] dark:text-zinc-400">
      {{ entry.description }}
    </p>

    <div class="flex min-h-5.5 w-full items-center gap-2">
      <View class="size-3.25 shrink-0 text-xs font-medium text-[#64748B] dark:text-zinc-400"/>
      <span
        class="text-xs font-semibold tabular-nums transition-colors"
        :class="viewsFlash ? 'text-[#2563EB] dark:text-blue-400' : 'text-[#DC2626] dark:text-red-400'"
      >{{ views }}</span>
      <span
        v-if="entry.ratingAverage != null"
        class="flex items-center gap-1 rounded-full bg-[#FEF3C7] dark:bg-amber-950 px-2 py-0.5"
      >
        <Star class="size-2.75 fill-[#F59E0B] text-[#F59E0B]" />
        <span class="text-[11px] font-bold text-[#B45309] dark:text-amber-300">{{ entry.ratingAverage.toFixed(1) }}</span>
      </span>
    </div>

    <a
      :href="readHref"
      class="mt-auto flex h-9.5 w-full items-center justify-center gap-2 rounded-lg bg-[#0891B2] text-[13px] font-bold text-white transition-colors hover:bg-[#0E7490]"
    >
      <Play class="size-3.25 fill-white" />
      Read Chapter 1
    </a>
  </article>
</template>
