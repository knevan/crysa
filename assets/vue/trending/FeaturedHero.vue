<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { ArrowUpRight, Star } from '@lucide/vue'
import {
  TRENDING_PERIODS,
  type TrendingItem,
  type TrendingLists,
  type TrendingPeriod,
} from '@/assets/vue/trending/types'

const props = defineProps<{
  lists: TrendingLists
}>()

const PLACEHOLDER = '/images/placeholder-cover.svg'
const FEATURED_COUNT = 5
const AUTOPLAY_MS = 6000
const RESUME_MS = 3000
const SWIPE_MIN_PX = 48

const PERIOD_EYEBROW: Record<TrendingPeriod, string> = {
  hour: 'HOT RIGHT NOW',
  day: 'TRENDING TODAY',
  week: 'TRENDING THIS WEEK',
  month: 'TRENDING THIS MONTH',
}

const STATUS_DOT: Record<string, string> = {
  ongoing: 'bg-emerald-500',
  completed: 'bg-sky-500',
  hiatus: 'bg-amber-500',
  discontinued: 'bg-zinc-400',
}

// Spotlight the top of the day list, falling back to the first period
// that has items (fresh/dev DBs often have an empty day window).
const sourcePeriod = computed<TrendingPeriod>(() => {
  return (
    TRENDING_PERIODS.find((period) => (props.lists[period]?.items ?? []).length > 0) ?? 'day'
  )
})

const slides = computed(() =>
  (props.lists[sourcePeriod.value]?.items ?? []).slice(0, FEATURED_COUNT),
)

const eyebrow = computed(() => PERIOD_EYEBROW[sourcePeriod.value])

const active = ref(0)

function coverOf(item: TrendingItem | null): string {
  return item?.coverUrl || PLACEHOLDER
}

function goTo(index: number) {
  if (slides.value.length === 0) return
  active.value = (index + slides.value.length) % slides.value.length
}

function itemAt(offset: number): TrendingItem | null {
  if (slides.value.length === 0) return null
  return slides.value[(active.value + offset + slides.value.length) % slides.value.length]!
}

// Coverflow: three visible, two hidden buffers at the far ends. All
// nodes persist across steps (keyed by slide id, single tag), so
// rotation animates in place instead of remounting. Circular, so the
// loop wraps to the start like the trending carousel.
//
// Poses are flat on purpose: tilt + scale + dim only, nothing sunk
// "into" the band (no translateZ anywhere).
function visibleOffsets(): number[] {
  const n = slides.value.length
  const span = n >= 5 ? 2 : n >= 3 ? 1 : 0
  const out: number[] = []
  for (let o = -span; o <= span; o++) out.push(o)
  return out
}

const EASE = 'cubic-bezier(0.22,0.61,0.36,1)'

function fanStyle(offset: number): Record<string, string> {
  const abs = Math.abs(offset)
  const base = {
    transition: `transform 0.7s ${EASE}, filter 0.7s ${EASE}, opacity 0.7s ${EASE}`,
  }
  if (abs === 0) {
    return {
      ...base,
      transform: 'translateX(0) rotateY(0deg) scale(1.04)',
      zIndex: '30',
      opacity: '1',
    }
  }
  if (abs === 1) {
    const dir = offset < 0 ? -1 : 1
    return {
      ...base,
      // Tilted fan pose: angled toward the centre plus a slight 2D
      // lean, dimmed. No depth push-back.
      transform: `translateX(${dir * 54}%) rotateY(0deg) rotate(${dir * 12}deg) scale(0.88)`,
      zIndex: '10',
      filter: 'brightness(0.72)',
      opacity: '1',
    }
  }
  // Hidden buffer: parked further out and transparent, waiting to swing in.
  const dir = offset < 0 ? -1 : 1
  return {
    ...base,
    transform: `translateX(${dir * 105}%) rotateY(0deg) rotate(${dir * 12}deg) scale(0.68)`,
    zIndex: '0',
    filter: 'brightness(0.45)',
    opacity: '0',
  }
}

function statusLabel(status: string): string {
  return status.charAt(0).toUpperCase() + status.slice(1)
}

function statusDot(status: string): string {
  return STATUS_DOT[status] ?? 'bg-zinc-400'
}

function ratingOf(item: TrendingItem | null): string | null {
  return item?.ratingAverage != null ? item.ratingAverage.toFixed(1) : null
}

function readerHref(item: TrendingItem | null): string | null {
  if (!item?.firstChapterKey) return null
  return `/series/${item.slug}/${item.firstChapterKey}`
}

const current = computed(() => slides.value[active.value] ?? null)

// --- Autoplay with 3s idle resume (same contract as TrendingCarousel) ---
// Interrupt sources: swipe, mouse hover, keyboard focus, manual nav, tab
// hidden. Clearing every source resumes rotation after RESUME_MS idle;
// reduced-motion never starts it.
let stepTimer: ReturnType<typeof setTimeout> | undefined
let resumeTimer: ReturnType<typeof setTimeout> | undefined
let hovering = false
let focused = false

function prefersReducedMotion(): boolean {
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

function clearTimers() {
  if (stepTimer !== undefined) {
    clearTimeout(stepTimer)
    stepTimer = undefined
  }
  if (resumeTimer !== undefined) {
    clearTimeout(resumeTimer)
    resumeTimer = undefined
  }
}

function interrupted(): boolean {
  return hovering || focused || document.hidden
}

function scheduleStep(delay: number) {
  clearTimers()
  if (slides.value.length < 2 || prefersReducedMotion()) return
  stepTimer = setTimeout(() => {
    stepTimer = undefined
    if (!interrupted()) goTo(active.value + 1)
    scheduleStep(AUTOPLAY_MS)
  }, delay)
}

function poke() {
  // Any manual interaction restarts the idle countdown.
  if (interrupted()) {
    clearTimers()
  } else {
    scheduleStep(RESUME_MS)
  }
}

function onVisibilityChange() {
  if (document.hidden) clearTimers()
  else scheduleStep(RESUME_MS)
}

// --- Swipe on the fan ---
// Cards stay anchored; a horizontal swipe past the distance threshold
// or a quick flick past the velocity threshold, steps one slide and the
// coverflow animation glides until it settles. Vertical gestures scroll.
let swipeStartX: number | null = null
let swipeStartY: number | null = null
let swipeStartT = 0
let justSwiped = false
const FLICK_MIN_PX = 12
const FLICK_VELOCITY_PX_MS = 0.4

function onFanPointerDown(e: PointerEvent) {
  if (slides.value.length < 2) return
  swipeStartX = e.clientX
  swipeStartY = e.clientY
  swipeStartT = performance.now()
  justSwiped = false
  clearTimers()
  try {
    ;(e.currentTarget as Element | null)?.setPointerCapture?.(e.pointerId)
  } catch {
    // Implicit touch capture still delivers the up event.
  }
}

function onFanPointerUp(e: PointerEvent) {
  if (swipeStartX === null || swipeStartY === null) return
  const dx = e.clientX - swipeStartX
  const dy = e.clientY - swipeStartY
  const dt = Math.max(1, performance.now() - swipeStartT)
  swipeStartX = null
  swipeStartY = null
  // Vertical intent wins: a page scroll must never step the carousel.
  if (Math.abs(dy) > Math.abs(dx) && Math.abs(dy) > 10) {
    scheduleStep(RESUME_MS)
    return
  }
  const flick = Math.abs(dx) >= FLICK_MIN_PX && Math.abs(dx) / dt >= FLICK_VELOCITY_PX_MS
  if (Math.abs(dx) >= SWIPE_MIN_PX || flick) {
    // A swipe already stepped; swallow the click that follows it.
    justSwiped = true
    goTo(active.value + (dx < 0 ? 1 : -1))
  }
  scheduleStep(RESUME_MS)
}

function onFanPointerCancel() {
  swipeStartX = null
  swipeStartY = null
  scheduleStep(RESUME_MS)
}

function onSideActivate(offset: number) {
  if (justSwiped) {
    justSwiped = false
    return
  }
  goTo(active.value + offset)
  poke()
}

function onHoverEnter(e: PointerEvent) {
  // Mouse only: touch-emulated pointer events must never latch hover.
  if (e.pointerType !== 'mouse') return
  hovering = true
  clearTimers()
}

function onHoverLeave(e: PointerEvent) {
  if (e.pointerType !== 'mouse') return
  hovering = false
  scheduleStep(RESUME_MS)
}

function onFocusIn() {
  focused = true
  clearTimers()
}

function onFocusOut() {
  focused = false
  scheduleStep(RESUME_MS)
}

function onImgError(e: Event) {
  const t = e.target as HTMLImageElement
  t.onerror = null
  t.src = PLACEHOLDER
}

onMounted(() => {
  scheduleStep(AUTOPLAY_MS)
  document.addEventListener('visibilitychange', onVisibilityChange)
})

onUnmounted(() => {
  clearTimers()
  document.removeEventListener('visibilitychange', onVisibilityChange)
})
</script>

<template>
  <section
    v-if="current"
    aria-label="Featured series"
    aria-roledescription="carousel"
    class="relative overflow-hidden rounded-3xl"
    @pointerenter="onHoverEnter"
    @pointerleave="onHoverLeave"
    @focusin="onFocusIn"
    @focusout="onFocusOut"
    @keydown.left="goTo(active - 1), poke()"
    @keydown.right="goTo(active + 1), poke()"
  >
    <!-- Blurred cover backdrop with crossfade; decorative only. -->
    <div aria-hidden="true" class="absolute inset-0">
      <img
        :key="coverOf(current)"
        :src="coverOf(current)"
        alt=""
        draggable="false"
        class="h-full w-full scale-125 object-cover blur-2xl saturate-150"
        @error="onImgError"
      />
      <div class="absolute inset-0 bg-background/75" />
      <div class="absolute inset-0 bg-linear-to-t from-background via-background/40 to-transparent" />
    </div>

    <div class="relative flex flex-col gap-6 p-5 sm:flex-row sm:items-center sm:gap-10 sm:p-8">
      <!-- Cover fan: display only, navigation lives on the buttons below.
           Swipe horizontally to step; vertical gestures scroll the page.
           Every slot renders the same tag keyed by slide id so rotation
           animates instead of remounting. -->
      <div
        class="relative mx-auto flex h-60 w-full max-w-105 touch-pan-y items-center justify-center perspective-distant select-none sm:mx-0 sm:h-80 sm:w-105 sm:shrink-0"
        @pointerdown="onFanPointerDown"
        @pointerup="onFanPointerUp"
        @pointercancel="onFanPointerCancel"
      >
        <template v-for="offset in visibleOffsets()" :key="itemAt(offset)!.id">
          <div
            :role="Math.abs(offset) === 1 ? 'button' : undefined"
            :tabindex="Math.abs(offset) === 1 ? 0 : undefined"
            :aria-label="Math.abs(offset) === 1 ? `Show featured: ${itemAt(offset)!.title}` : undefined"
            :aria-hidden="Math.abs(offset) === 2 ? 'true' : undefined"
            :class="[
              'absolute w-36 sm:w-52',
              Math.abs(offset) === 2 && 'pointer-events-none',
              Math.abs(offset) === 1 && 'cursor-pointer',
            ]"
            :style="fanStyle(offset)"
            @click="Math.abs(offset) === 1 && onSideActivate(offset)"
            @keydown.enter="Math.abs(offset) === 1 && onSideActivate(offset)"
          >
            <div
              :class="[
                'aspect-3/4 overflow-hidden rounded-xl',
                offset === 0
                  ? 'shadow-2xl ring-1 ring-white/25'
                  : 'shadow-xl ring-1 ring-white/15',
              ]"
            >
              <img
                :src="coverOf(itemAt(offset))"
                :alt="Math.abs(offset) === 2 ? '' : itemAt(offset)!.title"
                :loading="offset === 0 ? 'eager' : 'lazy'"
                decoding="async"
                draggable="false"
                class="pointer-events-none h-full w-full object-cover"
                @error="onImgError"
              />
            </div>
          </div>
        </template>
      </div>

      <!-- Info: eyebrow, title, meta, genre badges (max 3), CTAs. -->
      <Transition name="hero-fade" mode="out-in">
        <div :key="current.id" class="min-w-0 flex-1 text-center sm:text-left">
          <p class="font-mono text-[11px] tracking-[0.2em] text-muted-foreground">
            {{ eyebrow }}
          </p>

          <h2 class="mt-2 font-serif text-3xl leading-tight font-bold text-foreground sm:text-5xl">
            {{ current.title }}
          </h2>

          <div class="mt-3 flex flex-wrap items-center justify-center gap-x-3 gap-y-1.5 text-sm font-semibold text-foreground sm:justify-start">
            <span class="tabular-nums">Ch. {{ current.chapterCount }}</span>
            <span v-if="ratingOf(current) != null" class="inline-flex items-center gap-1">
              <Star class="size-4 fill-amber-400 text-amber-400" aria-hidden="true" />
              {{ ratingOf(current) }}
            </span>
            <span class="inline-flex items-center gap-1.5 text-muted-foreground">
              <span aria-hidden="true" :class="['size-1.5 rounded-full', statusDot(current.status)]" />
              {{ statusLabel(current.status) }}
            </span>
          </div>

          <div v-if="current.genres.length > 0" class="mt-3 flex flex-wrap items-center justify-center gap-1.5 sm:justify-start">
            <span
              v-for="genre in current.genres.slice(0, 3)"
              :key="genre"
              class="rounded-full border border-border bg-card/70 px-2.5 py-1 text-[11px] font-semibold text-muted-foreground backdrop-blur-sm"
            >
              {{ genre }}
            </span>
          </div>

          <div class="mt-4 flex flex-wrap items-center justify-center gap-2.5 sm:justify-start">
            <a
              :href="`/series/${current.slug}`"
              class="inline-flex items-center gap-1.5 rounded-lg bg-primary px-4 py-2 text-sm font-bold text-primary-foreground shadow transition-opacity hover:opacity-90"
            >
              Series Page
            </a>
            <a
              v-if="readerHref(current)"
              :href="readerHref(current)!"
              class="inline-flex items-center gap-1.5 rounded-lg border border-border bg-card/70 px-4 py-2 text-sm font-semibold text-foreground backdrop-blur-sm transition-colors hover:bg-accent"
            >
              Ch. 1
            </a>
            <a
              href="/series"
              class="inline-flex items-center gap-1.5 rounded-lg px-4 py-2 text-sm font-semibold text-muted-foreground transition-colors hover:text-foreground"
            >
              Browse Catalogue
              <ArrowUpRight class="size-4" aria-hidden="true" />
            </a>
          </div>
        </div>
      </Transition>
    </div>

    <!-- Dots -->
    <div class="relative flex items-center justify-center gap-1.5 pt-1 pb-4">
      <button
        v-for="(slide, i) in slides"
        :key="slide.id"
        type="button"
        :aria-label="`Go to featured: ${slide.title}`"
        :aria-current="i === active ? 'true' : undefined"
        :class="[
          'h-1.5 rounded-full transition-all',
          i === active ? 'w-6 bg-primary' : 'w-1.5 bg-muted-foreground/40 hover:bg-muted-foreground/70',
        ]"
        @click="goTo(i), poke()"
      />
    </div>
  </section>
</template>

<style scoped>
.hero-fade-enter-active,
.hero-fade-leave-active {
  transition: opacity 0.25s ease;
}

.hero-fade-enter-from,
.hero-fade-leave-to {
  opacity: 0;
}

@media (prefers-reduced-motion: reduce) {
  .hero-fade-enter-active,
  .hero-fade-leave-active {
    transition: none;
  }

  div {
    transition: none !important;
  }
}
</style>
