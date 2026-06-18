<script setup>
import { computed, ref, onMounted, onUnmounted } from 'vue'
import CellValue from './CellValue.vue'

const props = defineProps({
  data: [Array, Object],
})

const ROW_HEIGHT = 26
const BUFFER = 10

const expandedRows = ref(new Set())
const scrollContainer = ref(null)
const scrollTop = ref(0)
const viewHeight = ref(600)

const isArray = computed(() => Array.isArray(props.data))

const columns = computed(() => {
  if (!isArray.value) return ['Key', 'Value']
  const cols = new Set()
  const limit = Math.min(props.data.length, 100)
  for (let i = 0; i < limit; i++) {
    const row = props.data[i]
    if (row && typeof row === 'object' && !Array.isArray(row)) {
      Object.keys(row).forEach(k => cols.add(k))
    }
  }
  return Array.from(cols)
})

const rows = computed(() => {
  if (isArray.value) return props.data.filter(r => r && typeof r === 'object' && !Array.isArray(r))
  return Object.entries(props.data).map(([k, v]) => ({ _key: k, _value: v }))
})

const totalHeight = computed(() => rows.value.length * ROW_HEIGHT)

const visibleRange = computed(() => {
  const start = Math.max(0, Math.floor(scrollTop.value / ROW_HEIGHT) - BUFFER)
  const visibleCount = Math.ceil(viewHeight.value / ROW_HEIGHT) + BUFFER * 2
  const end = Math.min(rows.value.length, start + visibleCount)
  return { start, end }
})

const visibleRows = computed(() => {
  const { start, end } = visibleRange.value
  return rows.value.slice(start, end).map((row, i) => ({
    row,
    idx: start + i,
  }))
})

const offsetY = computed(() => visibleRange.value.start * ROW_HEIGHT)

function isExpandable(val) {
  return val !== null && typeof val === 'object'
}

function hasExpandableFields(row) {
  if (!isArray.value) return isExpandable(row._value)
  return Object.values(row).some(isExpandable)
}

function expandableEntries(row) {
  if (!isArray.value) {
    return isExpandable(row._value) ? [{ key: row._key, value: row._value }] : []
  }
  return Object.entries(row)
    .filter(([, v]) => isExpandable(v))
    .map(([k, v]) => ({ key: k, value: v }))
}

function toggleRow(idx) {
  if (expandedRows.value.has(idx)) {
    expandedRows.value.delete(idx)
  } else {
    expandedRows.value.add(idx)
  }
}

function onScroll() {
  if (scrollContainer.value) {
    scrollTop.value = scrollContainer.value.scrollTop
  }
}

let resizeObserver = null
onMounted(() => {
  if (scrollContainer.value) {
    viewHeight.value = scrollContainer.value.clientHeight
    resizeObserver = new ResizeObserver(() => {
      viewHeight.value = scrollContainer.value?.clientHeight || 600
    })
    resizeObserver.observe(scrollContainer.value)
  }
})

onUnmounted(() => {
  if (resizeObserver) resizeObserver.disconnect()
})
</script>

<template>
  <div ref="scrollContainer" class="flex-1 overflow-auto min-h-0 min-w-0" @scroll="onScroll">
    <table class="min-w-full text-xs border-collapse whitespace-nowrap">
      <thead>
        <tr class="bg-slate-100 border-b border-slate-200">
          <th class="px-1 py-0.5 w-6 bg-slate-100 sticky top-0 z-10" />
          <th class="px-2 py-0.5 text-left font-semibold text-slate-600 bg-slate-100 sticky top-0 z-10">Sr#</th>
          <th
            v-for="col in columns"
            :key="col"
            class="px-2 py-0.5 text-left font-semibold text-slate-600 bg-slate-100 sticky top-0 z-10"
          >
            {{ col }}
          </th>
        </tr>
      </thead>
      <tbody>
        <tr v-if="offsetY > 0" :style="{ height: offsetY + 'px' }">
          <td :colspan="columns.length + 2" />
        </tr>

        <template v-for="{ row, idx } in visibleRows" :key="idx">
          <tr class="border-b border-slate-100 hover:bg-blue-50" :style="{ height: ROW_HEIGHT + 'px' }">
            <td class="px-1 py-0.5 text-center align-top">
              <span
                v-if="hasExpandableFields(row)"
                class="text-blue-600 cursor-pointer font-bold select-none"
                @click="toggleRow(idx)"
              >
                {{ expandedRows.has(idx) ? '\u2212' : '+' }}
              </span>
            </td>
            <td class="px-2 py-0.5 align-top text-slate-400">{{ idx + 1 }}</td>

            <template v-if="!isArray">
              <td class="px-2 py-0.5 align-top font-medium text-slate-500">{{ row._key }}</td>
              <td class="px-2 py-0.5 align-top">
                <CellValue :value="row._value" />
              </td>
            </template>

            <template v-else>
              <td v-for="col in columns" :key="col" class="px-2 py-0.5 align-top">
                <CellValue :value="row[col]" />
              </td>
            </template>
          </tr>

          <tr
            v-if="expandedRows.has(idx)"
            v-for="entry in expandableEntries(row)"
            :key="entry.key"
            class="bg-slate-50 border-b border-slate-100"
          >
            <td class="px-1 py-0.5" />
            <td :colspan="columns.length + 1" class="px-2 py-1">
              <span class="text-xs font-semibold text-slate-500 mb-1 inline-block">{{ entry.key }}</span>
              <div class="sub-table-wrap">
                <DataTable :data="entry.value" />
              </div>
            </td>
          </tr>
        </template>

        <tr v-if="totalHeight - offsetY - (visibleRows.length * ROW_HEIGHT) > 0"
            :style="{ height: (totalHeight - offsetY - visibleRows.length * ROW_HEIGHT) + 'px' }">
          <td :colspan="columns.length + 2" />
        </tr>
      </tbody>
    </table>
  </div>
</template>
