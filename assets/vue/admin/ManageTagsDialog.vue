<script setup lang="ts">
import { ref, watch, nextTick, computed } from 'vue'
import {
  DialogRoot,
  DialogPortal,
  DialogOverlay,
  DialogContent,
  DialogTitle,
  DialogClose,
} from 'reka-ui'
import { X } from '@lucide/vue'
import { Input } from '@/assets/vue/components/ui/input'
import { Button } from '@/assets/vue/components/ui/button'

type Tag = { id: number; name: string }

const props = defineProps<{
  open: boolean
  tags: Tag[]
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'addTag', name: string): void
  (e: 'removeTag', id: number): void
}>()

const newTagName = ref('')
const inputRef = ref<HTMLInputElement | null>(null)

// Sorted A-Z for left-to-right display, locale-aware, case-insensitive
const sortedTags = computed(() =>
  [...props.tags].sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' })),
)

watch(
  () => props.open,
  async open => {
    if (open) {
      newTagName.value = ''
      await nextTick()
      // focus input when dialog opens
      const el = document.querySelector<HTMLInputElement>('[data-tags-input]')
      el?.focus()
    }
  },
)

function handleAdd() {
  const name = newTagName.value.trim()
  if (!name) return
  emit('addTag', name)
  newTagName.value = ''
}

function handleKeydown(e: KeyboardEvent) {
  if (e.key === 'Enter') {
    e.preventDefault()
    handleAdd()
  }
}
</script>

<template>
  <DialogRoot :open="open" @update:open="emit('update:open', $event)">
    <DialogPortal>
      <DialogOverlay class="fixed inset-0 z-50 bg-black/40 backdrop-blur-[1px]" />
      <DialogContent
        class="fixed left-1/2 top-1/2 z-50 w-full max-w-md -translate-x-1/2 -translate-y-1/2 rounded-lg border bg-card p-0 shadow-lg focus:outline-none"
        @escape-key-down="emit('update:open', false)"
      >
        <!-- Header -->
        <div class="flex items-center justify-between px-4 py-3">
          <DialogTitle class="text-sm font-semibold">Manage Category Tags</DialogTitle>
          <DialogClose
            class="rounded-md p-1.5 text-muted-foreground hover:bg-muted hover:text-foreground focus:outline-none focus:ring-1 focus:ring-ring"
            aria-label="Close"
            @click="emit('update:open', false)"
          >
            <X class="size-4" />
          </DialogClose>
        </div>

        <!-- Body -->
        <div class="px-4 pb-4 space-y-3">
          <!-- Input row -->
          <div class="flex gap-2 items-center">
            <Input
              data-tags-input
              v-model="newTagName"
              placeholder="Enter new tag name"
              class="flex-1 h-8"
              @keydown="handleKeydown"
            />
            <Button
              size="sm"
              class="h-8 px-4 shrink-0"
              :disabled="!newTagName.trim()"
              @click="handleAdd"
            >
              Add
            </Button>
          </div>

          <!-- Divider like image (thin blue line) — use neutral muted instead -->
          <div class="h-px bg-border" />

          <!-- Tags pills — sorted A-Z -->
          <div class="flex flex-wrap gap-1.5 min-h-7">
            <span
              v-for="tag in sortedTags"
              :key="tag.id"
              class="inline-flex items-center gap-1 rounded-full bg-muted px-2.5 py-1 text-xs font-medium text-muted-foreground hover:bg-muted/80 transition-colors"
            >
              {{ tag.name }}
              <button
                type="button"
                class="ml-0.5 rounded-full p-0.5 hover:bg-foreground/10 hover:text-foreground focus:outline-none focus:ring-1 focus:ring-ring"
                :aria-label="`Remove ${tag.name}`"
                @click="emit('removeTag', tag.id)"
              >
                <X class="size-3" />
              </button>
            </span>
            <span v-if="sortedTags.length === 0" class="text-xs text-muted-foreground py-1">
              No tags yet. Add one above.
            </span>
          </div>
        </div>
      </DialogContent>
    </DialogPortal>
  </DialogRoot>
</template>
