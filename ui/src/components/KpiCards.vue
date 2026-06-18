<script setup>
import { computed } from 'vue'

const props = defineProps({
  current: Object,
  vlogs: Array,
})

function fmt(n) {
  if (n == null || n === 0) return '0'
  if (n >= 1e9) return (n / 1e9).toFixed(1) + 'B'
  if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M'
  if (n >= 1e3) return (n / 1e3).toFixed(1) + 'K'
  return String(n)
}

function fmtBytes(b) {
  if (b == null || b === 0) return '0 B'
  if (b >= 1073741824) return (b / 1073741824).toFixed(2) + ' GB'
  if (b >= 1048576) return (b / 1048576).toFixed(1) + ' MB'
  if (b >= 1024) return (b / 1024).toFixed(1) + ' KB'
  return b + ' B'
}

function fmtLatency(us) {
  if (us == null || isNaN(us) || us === 0) return '-'
  if (us >= 1000) return (us / 1000).toFixed(1) + ' ms'
  return us.toFixed(0) + ' us'
}

const cards = computed(() => {
  const c = props.current
  if (!c) return []

  const db = c.db || {}
  const wal = c.wal || {}
  const vlog = c.vlog || {}
  const index = c.index || {}

  const totalVlogBytes = (props.vlogs || []).reduce((s, v) => s + (v.total_bytes || 0), 0)
  const totalDeadBytes = (props.vlogs || []).reduce((s, v) => s + (v.dead_bytes || 0), 0)
  const deadRatio = totalVlogBytes > 0 ? ((totalDeadBytes / totalVlogBytes) * 100).toFixed(1) : '0'

  return [
    { label: 'Total Reads', value: fmt(db.total_reads), color: 'text-blue-600' },
    { label: 'Total Writes', value: fmt(db.total_writes), color: 'text-green-600' },
    { label: 'Total Deletes', value: fmt(db.total_deletes), color: 'text-red-600' },
    { label: 'Read Latency', value: fmtLatency(db.avg_read_latency_us), color: 'text-indigo-600' },
    { label: 'Write Latency', value: fmtLatency(db.avg_write_latency_us), color: 'text-teal-600' },
    { label: 'WAL Bytes', value: fmtBytes(wal.total_bytes_written), color: 'text-amber-600' },
    { label: 'VLog Size', value: fmtBytes(totalVlogBytes), color: 'text-purple-600' },
    { label: 'Dead Ratio', value: deadRatio + '%', color: totalDeadBytes > 0 ? 'text-orange-600' : 'text-slate-600' },
  ]
})
</script>

<template>
  <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
    <div
      v-for="card in cards"
      :key="card.label"
      class="bg-slate-50 rounded-lg border border-slate-200 p-3"
    >
      <div class="text-xs text-slate-500 mb-1">{{ card.label }}</div>
      <div class="text-lg font-bold" :class="card.color">{{ card.value }}</div>
    </div>
  </div>
  <div v-if="!current" class="text-slate-400 text-sm p-4">No stats available</div>
</template>
