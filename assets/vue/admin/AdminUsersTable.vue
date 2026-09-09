<script setup lang="ts">
import { createColumnHelper, getCoreRowModel, useVueTable, FlexRender } from '@tanstack/vue-table'
import { computed, h, ref, watch } from 'vue'
import { Pencil, Trash2 } from '@lucide/vue'

export type UserRow = {
  id: number
  username: string
  email: string
  role: string | null
  active: boolean
  insertedAt: string | null
  updatedAt: string | null
}

const props = defineProps<{
  data: UserRow[]
}>()

const emit = defineEmits<{
  (e: 'edit', row: UserRow): void
  (e: 'delete', row: UserRow): void
}>()

const columnHelper = createColumnHelper<UserRow>()

function formatDate(iso: string | null): string {
  if (!iso) return '-'
  try {
    const d = new Date(iso)
    if (Number.isNaN(d.getTime())) return '-'
    return d.toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' })
  } catch {
    return '-'
  }
}

function roleClass(role: string | null): string {
  switch (role) {
    case 'superadmin':
      return 'bg-purple-100 text-purple-800 dark:bg-purple-900 dark:text-purple-100'
    case 'admin':
      return 'bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-100'
    case 'moderator':
      return 'bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-100'
    default:
      return 'bg-muted text-muted-foreground'
  }
}

// Reactive copy — same reason as AdminSeriesTable: LiveVue patches the source array
// in place (`splice`), TanStack only re-renders when the data ref changes.
const dataRef = computed(() => [...props.data])

// Column sizing — drag to resize
const columnSizing = ref<Record<string, number>>({})

const columns = [
  columnHelper.accessor('id', {
    header: 'ID',
    cell: info => info.getValue(),
    size: 50,
    minSize: 50,
    maxSize: 100,
    enableResizing: true,
  }),
  columnHelper.accessor('username', {
    header: 'Username',
    cell: info => {
      const v = info.getValue() as string
      return h('div', { class: 'font-medium truncate', title: v }, `@${v}`)
    },
    size: 150,
    minSize: 150,
    enableResizing: true,
  }),
  columnHelper.accessor('email', {
    header: 'Email',
    cell: info => {
      const v = info.getValue() as string
      return h('div', { class: 'truncate text-xs', title: v }, v)
    },
    size: 180,
    minSize: 180,
    enableResizing: true,
  }),
  columnHelper.accessor('role', {
    header: 'Role',
    cell: info => {
      const role = info.getValue() as string | null
      const label = role ?? 'unknown'
      return h(
        'span',
        {
          class: `inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium capitalize ${roleClass(role)}`,
        },
        label,
      )
    },
    size: 110,
    minSize: 110,
    enableResizing: true,
  }),
  columnHelper.accessor('active', {
    header: 'Status',
    cell: info => {
      const active = info.getValue() as boolean
      return h(
        'span',
        {
          class: `inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${
            active
              ? 'bg-emerald-100 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-100'
              : 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-100'
          }`,
        },
        active ? 'Active' : 'Inactive',
      )
    },
    size: 100,
    minSize: 100,
    enableResizing: true,
  }),
  columnHelper.accessor('insertedAt', {
    header: 'Joined',
    cell: info => formatDate(info.getValue() as string | null),
    size: 130,
    minSize: 130,
    enableResizing: true,
  }),
  columnHelper.display({
    id: 'actions',
    header: 'Actions',
    cell: info => {
      const row = info.row.original
      return h('div', { class: 'flex gap-1' }, [
        h(
          'button',
          {
            class:
              'inline-flex h-7 w-7 items-center justify-center rounded-md border border-input bg-background text-xs hover:bg-accent',
            title: `Edit ${row.username} — username/email/role/active (hierarchy enforced)`,
            onClick: () => emit('edit', row),
          },
          [h(Pencil, { class: 'size-3.5' })],
        ),
        h(
          'button',
          {
            class:
              'inline-flex h-7 w-7 items-center justify-center rounded-md border border-input bg-background text-xs hover:bg-accent hover:text-destructive',
            title: `Delete ${row.username} — hard delete, cannot delete self or ≥ your role`,
            onClick: () => emit('delete', row),
          },
          [h(Trash2, { class: 'size-3.5' })],
        ),
      ])
    },
    size: 183,
    minSize: 183,
    enableResizing: true,
  }),
]

const table = useVueTable({
  data: dataRef,
  columns,
  state: {
    get columnSizing() {
      return columnSizing.value
    },
  },
  onColumnSizingChange: updater => {
    const next = typeof updater === 'function' ? updater(columnSizing.value) : updater
    columnSizing.value = next
  },
  columnResizeMode: 'onChange',
  enableColumnResizing: true,
  getCoreRowModel: getCoreRowModel(),
})

const headerGroups = computed(() => table.getHeaderGroups())
const rows = computed(() => {
  const _track = dataRef.value.length
  const r = table.getRowModel().rows
  return r
})

watch(
  () => props.data,
  (newData) => {
    table.setOptions((prev) => ({ ...prev, data: [...newData] }))
  },
  { deep: true },
)

watch(dataRef, (v) => {
  table.setOptions((prev) => ({ ...prev, data: [...v] }))
})
</script>

<template>
  <div class="w-full overflow-x-auto border-t">
    <table class="caption-bottom text-sm" :style="{ width: table.getTotalSize() + 'px', tableLayout: 'fixed' }">
      <thead class="[&_tr]:border-b bg-muted/50">
        <tr v-for="headerGroup in headerGroups" :key="headerGroup.id" class="border-b">
          <th
            v-for="(header, idx) in headerGroup.headers"
            :key="header.id"
            class="relative h-9 px-3 text-left align-middle font-medium text-muted-foreground whitespace-nowrap select-none"
            :style="header.column.getSize() ? `width: ${header.column.getSize()}px` : undefined"
          >
            <FlexRender
              v-if="!header.isPlaceholder"
              :render="header.column.columnDef.header"
              :props="header.getContext()"
            />
            <div
              v-if="header.column.getCanResize()"
              class="group/handle absolute right-0 top-0 flex h-full w-3 -mr-1.5 cursor-col-resize touch-none select-none justify-center"
              @mousedown="header.getResizeHandler()?.($event)"
              @touchstart="header.getResizeHandler()?.($event)"
            >
              <div
                class="h-full w-px bg-border transition-colors group-hover/handle:bg-foreground"
                :class="{ 'bg-foreground!': header.column.getIsResizing() }"
              />
            </div>
            <div v-else-if="idx < headerGroup.headers.length - 1 && !header.isPlaceholder" class="absolute right-0 top-0 h-full w-px bg-border" />
          </th>
        </tr>
      </thead>
      <tbody class="[&_tr:last-child]:border-0">
        <tr
          v-for="row in rows"
          :key="row.id"
          class="border-b transition-colors hover:bg-muted/50"
        >
          <td v-for="cell in row.getVisibleCells()" :key="cell.id" class="p-3 align-middle border-r border-border [&:last-child]:border-r-0">
            <FlexRender :render="cell.column.columnDef.cell" :props="cell.getContext()" />
          </td>
        </tr>
        <tr v-if="rows.length === 0">
          <td :colspan="columns.length" class="h-24 text-center text-muted-foreground">
            No users found
          </td>
        </tr>
      </tbody>
    </table>
  </div>
</template>
