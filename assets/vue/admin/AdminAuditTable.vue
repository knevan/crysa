<script setup lang="ts">
import { createColumnHelper, getCoreRowModel, useVueTable, FlexRender } from '@tanstack/vue-table'
import { computed, h, ref, watch } from 'vue'

export type AuditRow = {
  id: number
  actorId: number | null
  actorRole: string
  actorUsername: string | null
  action: string
  targetType: string
  targetId: number | null
  targetIdentifier: string | null
  metadata: Record<string, unknown> | null
  ipAddress: string | null
  userAgent: string | null
  insertedAt: string | null
}

const props = defineProps<{
  data: AuditRow[]
}>()

const columnHelper = createColumnHelper<AuditRow>()

function formatDate(iso: string | null): string {
  if (!iso) return '-'
  try {
    const d = new Date(iso)
    if (Number.isNaN(d.getTime())) return '-'
    return d.toLocaleString('en-US', {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    })
  } catch {
    return '-'
  }
}

function actionClass(action: string): string {
  if (action.startsWith('series.')) return 'bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-100'
  if (action.startsWith('user.')) return 'bg-purple-100 text-purple-800 dark:bg-purple-900 dark:text-purple-100'
  if (action.startsWith('chapter.')) return 'bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-100'
  if (action.startsWith('category.')) return 'bg-emerald-100 text-emerald-800 dark:bg-emerald-900 dark:text-emerald-100'
  if (action.startsWith('report.')) return 'bg-zinc-100 text-zinc-800 dark:bg-zinc-800 dark:text-zinc-100'
  return 'bg-muted text-muted-foreground'
}

const dataRef = computed(() => [...props.data])

const columnSizing = ref<Record<string, number>>({})

const columns = [
  columnHelper.accessor('id', {
    header: 'ID',
    cell: info => info.getValue(),
    size: 70,
    minSize: 50,
    maxSize: 90,
    enableResizing: true,
  }),
  columnHelper.accessor('insertedAt', {
    header: 'When',
    cell: info => h('span', { class: 'text-xs tabular-nums', title: info.getValue() as string | null }, formatDate(info.getValue() as string | null)),
    size: 150,
    minSize: 130,
    enableResizing: true,
  }),
  columnHelper.accessor('actorUsername', {
    header: 'Actor',
    cell: info => {
      const row = info.row.original
      const label = row.actorUsername ? `${row.actorUsername} (${row.actorRole})` : row.actorRole
      return h('div', { class: 'truncate text-xs', title: label }, label)
    },
    size: 140,
    minSize: 120,
    enableResizing: true,
  }),
  columnHelper.accessor('action', {
    header: 'Action',
    cell: info => {
      const v = info.getValue() as string
      return h('span', { class: `inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium ${actionClass(v)}` }, v)
    },
    size: 150,
    minSize: 130,
    enableResizing: true,
  }),
  columnHelper.accessor('targetType', {
    header: 'Target',
    cell: info => {
      const row = info.row.original
      const t = row.targetType
      const id = row.targetId ? `#${row.targetId}` : ''
      const ident = row.targetIdentifier ? ` ${row.targetIdentifier.slice(0, 30)}` : ''
      return h('span', { class: 'text-xs truncate block', title: `${t} ${id} ${row.targetIdentifier ?? ''}` }, `${t} ${id}${ident}`)
    },
    size: 200,
    minSize: 150,
    enableResizing: true,
  }),
  columnHelper.accessor('ipAddress', {
    header: 'IP',
    cell: info => h('span', { class: 'text-xs font-mono text-muted-foreground' }, (info.getValue() as string | null) || '—'),
    size: 130,
    minSize: 100,
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

const headerGroups = computed(() => {
  const _track = dataRef.value.length
  return table.getHeaderGroups()
})
const rows = computed(() => {
  const _track = dataRef.value.length
  return table.getRowModel().rows
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
              <div class="h-full w-px bg-border transition-colors group-hover/handle:bg-foreground" :class="{ 'bg-foreground!': header.column.getIsResizing() }" />
            </div>
            <div v-else-if="idx < headerGroup.headers.length - 1 && !header.isPlaceholder" class="absolute right-0 top-0 h-full w-px bg-border" />
          </th>
        </tr>
      </thead>
      <tbody class="[&_tr:last-child]:border-0">
        <tr v-for="row in rows" :key="row.id" class="border-b transition-colors hover:bg-muted/50">
          <td v-for="cell in row.getVisibleCells()" :key="cell.id" class="p-3 align-middle border-r border-border last:border-r-0">
            <FlexRender :render="cell.column.columnDef.cell" :props="cell.getContext()" />
          </td>
        </tr>
        <tr v-if="rows.length === 0">
          <td :colspan="columns.length" class="h-24 text-center text-muted-foreground">No audit logs</td>
        </tr>
      </tbody>
    </table>
  </div>
</template>
