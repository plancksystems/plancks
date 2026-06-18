<script setup>
import { computed } from 'vue'

const props = defineProps({
  vlogs: Array,
  gcDeadRatio: { type: Number, default: 30 },
})

function fmtBytes(b) {
  if (b == null || b === 0) return '0 B'
  if (b >= 1073741824) return (b / 1073741824).toFixed(2) + ' GB'
  if (b >= 1048576) return (b / 1048576).toFixed(1) + ' MB'
  if (b >= 1024) return (b / 1024).toFixed(1) + ' KB'
  return b + ' B'
}

function ratioClass(ratio) {
  if (ratio >= 0.7) return 'text-red-600 font-semibold'
  if (ratio >= 0.4) return 'text-orange-600'
  return 'text-slate-700'
}

function ratioBarWidth(ratio) {
  return Math.min(ratio * 100, 100) + '%'
}

function ratioBarColor(ratio) {
  if (ratio >= 0.7) return 'bg-red-500'
  if (ratio >= 0.4) return 'bg-orange-400'
  return 'bg-green-500'
}

const sorted = computed(() =>
  [...(props.vlogs || [])].sort((a, b) => (a.vlog_id || 0) - (b.vlog_id || 0))
)

const totals = computed(() => {
  const t = { count: 0, deleted: 0, total_bytes: 0, live_bytes: 0, dead_bytes: 0 }
  for (const v of sorted.value) {
    t.count += v.count || 0
    t.deleted += v.deleted || 0
    t.total_bytes += v.total_bytes || 0
    t.live_bytes += v.live_bytes || 0
    t.dead_bytes += v.dead_bytes || 0
  }
  return t
})
</script>

<template>
  <div v-if="!vlogs || vlogs.length === 0" class="text-slate-400 text-sm p-4">
    No VLog data available.
  </div>

  <div v-else>
    <div class="grid grid-cols-2 md:grid-cols-5 gap-3 mb-4">
      <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
        <div class="text-xs text-slate-500">VLogs</div>
        <div class="text-lg font-bold text-slate-700">{{ sorted.length }}</div>
      </div>
      <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
        <div class="text-xs text-slate-500">Total Entries</div>
        <div class="text-lg font-bold text-blue-600">{{ totals.count.toLocaleString() }}</div>
      </div>
      <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
        <div class="text-xs text-slate-500">Total Size</div>
        <div class="text-lg font-bold text-purple-600">{{ fmtBytes(totals.total_bytes) }}</div>
      </div>
      <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
        <div class="text-xs text-slate-500">Live Size</div>
        <div class="text-lg font-bold text-green-600">{{ fmtBytes(totals.live_bytes) }}</div>
      </div>
      <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
        <div class="text-xs text-slate-500">Dead Size</div>
        <div class="text-lg font-bold" :class="totals.dead_bytes > 0 ? 'text-orange-600' : 'text-slate-600'">{{ fmtBytes(totals.dead_bytes) }}</div>
      </div>
    </div>

    <div class="overflow-x-auto rounded-lg border border-slate-200">
      <table class="w-full text-sm">
        <thead class="bg-slate-100 text-slate-600">
          <tr>
            <th class="px-3 py-2 text-left font-medium">ID</th>
            <th class="px-3 py-2 text-right font-medium">Entries</th>
            <th class="px-3 py-2 text-right font-medium">Deleted</th>
            <th class="px-3 py-2 text-right font-medium">Total</th>
            <th class="px-3 py-2 text-right font-medium">Live</th>
            <th class="px-3 py-2 text-right font-medium">Dead</th>
            <th class="px-3 py-2 text-left font-medium" style="min-width: 140px">Dead Ratio</th>
            <th class="px-3 py-2 text-center font-medium">Tail</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="v in sorted"
            :key="v.vlog_id"
            class="border-t border-slate-100 hover:bg-slate-50"
          >
            <td class="px-3 py-1.5 font-mono text-slate-700">{{ v.vlog_id }}</td>
            <td class="px-3 py-1.5 text-right">{{ (v.count || 0).toLocaleString() }}</td>
            <td class="px-3 py-1.5 text-right">{{ (v.deleted || 0).toLocaleString() }}</td>
            <td class="px-3 py-1.5 text-right">{{ fmtBytes(v.total_bytes) }}</td>
            <td class="px-3 py-1.5 text-right text-green-700">{{ fmtBytes(v.live_bytes) }}</td>
            <td class="px-3 py-1.5 text-right" :class="(v.dead_bytes || 0) > 0 ? 'text-orange-600' : ''">{{ fmtBytes(v.dead_bytes) }}</td>
            <td class="px-3 py-1.5">
              <div class="flex items-center gap-2">
                <div class="flex-1 h-2 bg-slate-200 rounded-full overflow-hidden">
                  <div
                    class="h-full rounded-full transition-all"
                    :class="ratioBarColor(v.dead_ratio || 0)"
                    :style="{ width: ratioBarWidth(v.dead_ratio || 0) }"
                  />
                </div>
                <span class="text-xs w-10 text-right" :class="ratioClass(v.dead_ratio || 0)">
                  {{ ((v.dead_ratio || 0) * 100).toFixed(1) }}%
                </span>
              </div>
            </td>
            <td class="px-3 py-1.5 text-center">
              <span v-if="v.is_tail" class="inline-block w-2 h-2 rounded-full bg-green-500" title="Active tail" />
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
