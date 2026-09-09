<script setup lang="ts">
import { ref, watch } from 'vue'
import {
  DialogRoot,
  DialogPortal,
  DialogOverlay,
  DialogContent,
  DialogTitle,
  DialogClose,
} from 'reka-ui'
import { X } from '@lucide/vue'
import { Button } from '@/assets/vue/components/ui/button'
import { Input } from '@/assets/vue/components/ui/input'
import { Label } from '@/assets/vue/components/ui/label'

export type UserRow = {
  id: number
  username: string
  email: string
  role: string | null
  active: boolean
}

const props = defineProps<{
  open: boolean
  user: UserRow | null
}>()

const emit = defineEmits<{
  (e: 'update:open', v: boolean): void
  (e: 'save', data: { id: number; username: string; email: string; role: string; active: boolean }): void
}>()

const username = ref('')
const email = ref('')
const role = ref('user')
const active = ref(true)
const error = ref<string | null>(null)

const roles = ['user', 'moderator', 'admin', 'superadmin'] as const

watch(
  () => props.user,
  u => {
    if (u) {
      username.value = u.username
      email.value = u.email
      role.value = (u.role || 'user').toLowerCase()
      active.value = u.active
      error.value = null
    }
  },
  { immediate: true },
)

watch(
  () => props.open,
  o => {
    if (o && props.user) {
      username.value = props.user.username
      email.value = props.user.email
      role.value = (props.user.role || 'user').toLowerCase()
      active.value = props.user.active
      error.value = null
    }
  },
)

function validate(): string | null {
  const u = username.value.trim()
  if (!u) return 'Username is required'
  if (!/^[a-zA-Z0-9]+$/.test(u)) return 'Username may only contain letters and numbers'
  if (u.length < 3 || u.length > 40) return 'Username must be 3–40 characters'
  const e = email.value.trim()
  if (!e) return 'Email is required'
  if (!/^[^\s]+@[^\s]+$/.test(e)) return 'Email must contain @ and no spaces'
  if (e.length > 254) return 'Email too long'
  if (!(roles as readonly string[]).includes(role.value)) return 'Invalid role'
  return null
}

function onSave() {
  const msg = validate()
  if (msg) {
    error.value = msg
    return
  }
  if (!props.user) return
  emit('save', {
    id: props.user.id,
    username: username.value.trim(),
    email: email.value.trim().toLowerCase(),
    role: role.value,
    active: active.value,
  })
}
</script>

<template>
  <DialogRoot :open="open" @update:open="emit('update:open', $event)">
    <DialogPortal>
      <DialogOverlay class="fixed inset-0 z-50 bg-black/40 backdrop-blur-[1px]" />
      <DialogContent
        class="fixed left-1/2 top-1/2 z-50 w-full max-w-lg -translate-x-1/2 -translate-y-1/2 rounded-xl border bg-card shadow-xl focus:outline-none flex flex-col"
        @escape-key-down="emit('update:open', false)"
      >
        <div class="flex items-center justify-between px-6 py-4 border-b">
          <DialogTitle class="text-base font-semibold">
            Edit User — {{ user?.username || '' }}
          </DialogTitle>
          <DialogClose class="rounded-md p-1.5 text-muted-foreground hover:bg-muted" @click="emit('update:open', false)">
            <X class="size-4" />
          </DialogClose>
        </div>

        <div class="p-6 space-y-4">
          <p class="text-xs text-muted-foreground">
            Hierarchy: you cannot edit users at or above your own level, and you cannot assign a role ≥ your own. You cannot edit yourself.
          </p>

          <div class="space-y-1.5">
            <Label for="edit-username" class="text-sm font-medium">Username</Label>
            <Input id="edit-username" v-model="username" class="h-9" placeholder="username" />
            <p class="text-xs text-muted-foreground">Letters and numbers only, 3–40 chars. Unique case-sensitive.</p>
          </div>

          <div class="space-y-1.5">
            <Label for="edit-email" class="text-sm font-medium">Email</Label>
            <Input id="edit-email" v-model="email" type="email" class="h-9" placeholder="user@example.com" />
            <p class="text-xs text-muted-foreground">Normalized to lower-case. Unique case-insensitive.</p>
          </div>

          <div class="grid grid-cols-2 gap-4">
            <div class="space-y-1.5">
              <Label class="text-sm font-medium">Role</Label>
              <select v-model="role" class="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm">
                <option v-for="r in roles" :key="r" :value="r" class="capitalize">{{ r }}</option>
              </select>
            </div>
            <div class="space-y-1.5">
              <Label class="text-sm font-medium">Status</Label>
              <select v-model="active" class="flex h-9 w-full rounded-md border border-input bg-transparent px-3 py-1 text-sm">
                <option :value="true">Active</option>
                <option :value="false">Inactive</option>
              </select>
            </div>
          </div>

          <p v-if="error" class="text-sm text-destructive bg-destructive/10 border border-destructive/20 rounded px-3 py-2">{{ error }}</p>
        </div>

        <div class="flex justify-end gap-2 px-6 py-4 border-t bg-muted/10">
          <Button variant="outline" class="h-8" @click="emit('update:open', false)">Cancel</Button>
          <Button class="h-8" @click="onSave">Save changes</Button>
        </div>
      </DialogContent>
    </DialogPortal>
  </DialogRoot>
</template>
