<script setup lang="ts">
import { createColumnHelper, getCoreRowModel, useVueTable, FlexRender } from '@tanstack/vue-table'
import { computed, h, ref, watch } from 'vue'
import { Check, X } from '@lucide/vue'

export type ReportRow = {
  id: number
  reason: string
  details: string | null
  status: string
  reporter: string | null
  targetType: 'chapter' | 'comment'
  targetId: number
  insertedAt: string | null
  resolvedAt: string | null
}

const props = defineProps<{
  data: ReportRow[]
}>()

const emit = defineEmits<{
  (e: 'resolve', id: number): void
  (e: 'reject', id: number): void
}>()

const columnHelper = createColumnHelper<ReportRow>()

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

function statusClass(status: string): string {
  switch (status) {
    case 'pending':
      return 'bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-100'
    case 'resolved':
      return 'bg-emerald-100 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-100'
    case 'rejected':
      return 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-100'
    default:
      return 'bg-muted text-muted-foreground'
  }
}

function reasonClass(reason: string): string {
  // chapter reasons vs comment reasons
  return 'bg-muted text-muted-foreground'
}

const dataRef = computed(() => [...props.data])

const columnSizing = ref<Record<string, number>>({})

const columns = [
  columnHelper.accessor('id', {
    header: 'ID',
    cell: info => info.getValue(),
    size: 60,
    minSize: 50,
    maxSize: 100,
    enableResizing: true,
  }),
  columnHelper.accessor('reporter', {
    header: 'Reporter',
    cell: info => {
      const v = info.getValue() as string | null
      return h('div', { class: 'truncate font-medium', title: v ?? '' }, v ? `@${v}` : '-')
    },
    size: 100,
    minSize: 100,
    enableResizing: true,
  }),
  columnHelper.accessor('reason', {
    header: 'Reason',
    cell: info => {
      const r = info.getValue() as string
      return h('span', { class: `inline-flex items-center rounded-full px-2 py-0.5 text-xs capitalize ${reasonClass(r)}` }, r.replace(/_/g, ' '))
    },
    size: 140,
    minSize: 140,
    enableResizing: true,
  }),
  columnHelper.accessor('status', {
    header: 'Status',
    cell: info => {
      const s = info.getValue() as string
      return h('span', { class: `inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium capitalize ${statusClass(s)}` }, s)
    },
    size: 130,
    minSize: 130,
    enableResizing: true,
  }),
  columnHelper.accessor('targetType', {
    header: 'Target',
    cell: info => {
      const row = info.row.original
      const label = row.targetType === 'chapter' ? `Chapter #${row.targetId}` : `Comment #${row.targetId}`
      return h('span', { class: 'text-xs truncate', title: label }, label)
    },
    size: 140,
    minSize: 140,
    enableResizing: true,
  }),
  columnHelper.accessor('insertedAt', {
    header: 'Reported',
    cell: info => formatDate(info.getValue() as string | null),
    size: 120,
    minSize: 120,
    enableResizing: true,
  }),
  columnHelper.display({
    id: 'actions',
    header: 'Actions',
    cell: info => {
      const row = info.row.original
      const isPending = row.status === 'pending'
      return h('div', { class: 'flex gap-1' }, [
        h(
          'button',
          {
            class:
              'inline-flex h-7 px-2 items-center justify-center rounded-md border bg-emerald-50 text-emerald-700 border-emerald-200 text-xs hover:bg-emerald-100 disabled:opacity-50 disabled:pointer-events-none gap-1',
            disabled: !isPending,
            title: isPending ? 'Resolve report' : 'Already resolved',
            onClick: () => isPending && emit('resolve', row.id),
          },
          [h(Check, { class: 'size-3.5' }), 'Resolve'],
        ),
        h(
          'button',
          {
            class:
              'inline-flex h-7 px-2 items-center justify-center rounded-md border bg-red-50 text-red-700 border-red-200 text-xs hover:bg-red-100 disabled:opacity-50 disabled:pointer-events-none gap-1',
            disabled: !isPending,
            title: isPending ? 'Reject report' : 'Already resolved',
            onClick: () => isPending && emit('reject', row.id),
          },
          [h(X, { class: 'size-3.5' }), 'Reject'],
        ),
      ])
    },
    size: 213,
    minSize: 213,
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
  return table.getRowModel().rows
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
                :class="{ '!bg-foreground': header.column.getIsResizing() }"
              />
            </div>
            <div v-else-if="idx < headerGroup.headers.length - 1 && !header.isPlaceholder" class="absolute right-0 top-0 h-full w-px bg-border" />
          </th>
        </tr>
      </thead>
      <tbody class="[&_tr:last-child]:border-0">
        <tr v-for="row in rows" :key="row.id" class="border-b transition-colors hover:bg-muted/50">
          <td
            v-for="cell in row.getVisibleCells()"
            :key="cell.id"
            class="p-3 align-middle border-r border-border [&:last-child]:border-r-0"
          >
            <FlexRender :render="cell.column.columnDef.cell" :props="cell.getContext()" />
          </td>
        </tr>
        <tr v-if="rows.length === 0">
          <td :colspan="columns.length" class="h-24 text-center text-muted-foreground">No reports found</td>
        </tr>
      </tbody>
    </table>
  </div>
</template>
