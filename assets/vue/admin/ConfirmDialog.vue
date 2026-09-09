<script setup lang="ts">
import {
  DialogRoot,
  DialogPortal,
  DialogOverlay,
  DialogContent,
  DialogTitle,
} from 'reka-ui'
import { Button } from '@/assets/vue/components/ui/button'

withDefaults(
  defineProps<{
    open: boolean
    title?: string
    description?: string
    confirmLabel?: string
    cancelLabel?: string
    variant?: 'default' | 'destructive'
  }>(),
  {
    title: 'Are you sure?',
    description: 'This action cannot be undone.',
    confirmLabel: 'Confirm',
    cancelLabel: 'Cancel',
    variant: 'destructive',
  },
)

const emit = defineEmits<{
  (e: 'update:open', v: boolean): void
  (e: 'confirm'): void
  (e: 'cancel'): void
}>()

function onCancel() {
  emit('cancel')
  emit('update:open', false)
}

function onConfirm() {
  emit('confirm')
  // parent controls closing via update:open, but also close here for immediate feedback
  // keep open handling to parent; we don't auto-close on confirm to allow parent to decide
}
</script>

<template>
  <DialogRoot :open="open" @update:open="emit('update:open', $event)">
    <DialogPortal>
      <DialogOverlay class="fixed inset-0 z-50 bg-black/40 backdrop-blur-[1px]" />
      <DialogContent
        class="fixed left-1/2 top-1/2 z-50 w-full max-w-110 -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-card shadow-xl focus:outline-none p-0 overflow-hidden"
        @escape-key-down="emit('update:open', false)"
      >
        <div class="px-6 pt-6 pb-4 space-y-2">
          <DialogTitle class="text-[15px] font-semibold leading-6 text-foreground">
            {{ title }}
          </DialogTitle>
          <p class="text-sm leading-5 text-muted-foreground">
            {{ description }}
          </p>
        </div>
        <div class="flex justify-end gap-3 px-6 py-4">
          <Button variant="outline" class="h-9 rounded-md px-5 border-border bg-background hover:bg-muted" @click="onCancel">
            {{ cancelLabel }}
          </Button>
          <Button :variant="variant" class="h-9 rounded-md px-5 font-medium" @click="onConfirm">
            {{ confirmLabel }}
          </Button>
        </div>
      </DialogContent>
    </DialogPortal>
  </DialogRoot>
</template>
