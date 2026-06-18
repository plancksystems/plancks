<script setup>
import { computed } from 'vue'
import { Line } from 'vue-chartjs'
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  Title,
  Tooltip,
  Legend,
  Filler,
} from 'chart.js'

ChartJS.register(CategoryScale, LinearScale, PointElement, LineElement, Title, Tooltip, Legend, Filler)

const props = defineProps({
  history: Array,
  mode: String,
})

const chartOptions = {
  responsive: true,
  maintainAspectRatio: false,
  interaction: { mode: 'index', intersect: false },
  plugins: {
    legend: { position: 'bottom', labels: { boxWidth: 12, font: { size: 11 } } },
    tooltip: { bodyFont: { size: 11 } },
  },
  scales: {
    x: { ticks: { font: { size: 10 }, maxRotation: 45 } },
    y: { beginAtZero: true, ticks: { font: { size: 10 } } },
  },
  elements: {
    point: { radius: 2, hoverRadius: 4 },
    line: { tension: 0.3, borderWidth: 2 },
  },
}

const labels = computed(() =>
  (props.history || []).map(s => {
    if (!s.ts) return ''
    const d = new Date(s.ts)
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
  })
)

const overviewOpsChart = computed(() => ({
  labels: labels.value,
  datasets: [
    { label: 'Reads', data: props.history.map(s => s.db?.total_reads || 0), borderColor: '#3b82f6', backgroundColor: '#3b82f620', fill: true },
    { label: 'Writes', data: props.history.map(s => s.db?.total_writes || 0), borderColor: '#22c55e', backgroundColor: '#22c55e20', fill: true },
    { label: 'Deletes', data: props.history.map(s => s.db?.total_deletes || 0), borderColor: '#ef4444', backgroundColor: '#ef444420', fill: true },
  ],
}))

const overviewLatencyChart = computed(() => ({
  labels: labels.value,
  datasets: [
    { label: 'Read Latency (us)', data: props.history.map(s => safeNum(s.db?.avg_read_latency_us)), borderColor: '#6366f1', backgroundColor: '#6366f120', fill: true },
    { label: 'Write Latency (us)', data: props.history.map(s => safeNum(s.db?.avg_write_latency_us)), borderColor: '#14b8a6', backgroundColor: '#14b8a620', fill: true },
  ],
}))

const opsDbChart = computed(() => ({
  labels: labels.value,
  datasets: [
    { label: 'DB Reads', data: props.history.map(s => s.db?.total_reads || 0), borderColor: '#3b82f6' },
    { label: 'DB Writes', data: props.history.map(s => s.db?.total_writes || 0), borderColor: '#22c55e' },
    { label: 'DB Updates', data: props.history.map(s => s.db?.total_updates || 0), borderColor: '#f59e0b' },
    { label: 'DB Deletes', data: props.history.map(s => s.db?.total_deletes || 0), borderColor: '#ef4444' },
  ],
}))

const opsWalChart = computed(() => ({
  labels: labels.value,
  datasets: [
    { label: 'WAL Appends', data: props.history.map(s => s.wal?.total_appends || 0), borderColor: '#8b5cf6' },
    { label: 'WAL Fsyncs', data: props.history.map(s => s.wal?.total_fsyncs || 0), borderColor: '#f97316' },
    { label: 'WAL Flushes', data: props.history.map(s => s.wal?.total_flushes || 0), borderColor: '#06b6d4' },
  ],
}))

const opsIndexChart = computed(() => ({
  labels: labels.value,
  datasets: [
    { label: 'Index Inserts', data: props.history.map(s => s.index?.total_inserts || 0), borderColor: '#22c55e' },
    { label: 'Index Searches', data: props.history.map(s => s.index?.total_searches || 0), borderColor: '#3b82f6' },
    { label: 'Index Scans', data: props.history.map(s => s.index?.total_scans || 0), borderColor: '#a855f7' },
  ],
}))

const opsVlogChart = computed(() => ({
  labels: labels.value,
  datasets: [
    { label: 'VLog Reads', data: props.history.map(s => s.vlog?.total_reads || 0), borderColor: '#3b82f6' },
    { label: 'VLog Writes', data: props.history.map(s => s.vlog?.total_writes || 0), borderColor: '#22c55e' },
    { label: 'GC Runs', data: props.history.map(s => s.vlog?.total_gc_runs || 0), borderColor: '#ef4444' },
  ],
}))

const latencyDbChart = computed(() => ({
  labels: labels.value,
  datasets: [
    { label: 'Read (us)', data: props.history.map(s => safeNum(s.db?.avg_read_latency_us)), borderColor: '#3b82f6' },
    { label: 'Write (us)', data: props.history.map(s => safeNum(s.db?.avg_write_latency_us)), borderColor: '#22c55e' },
    { label: 'Update (us)', data: props.history.map(s => safeNum(s.db?.avg_update_latency_us)), borderColor: '#f59e0b' },
    { label: 'Flush (us)', data: props.history.map(s => safeNum(s.db?.avg_flush_latency_us)), borderColor: '#06b6d4' },
  ],
}))

const latencyWalChart = computed(() => ({
  labels: labels.value,
  datasets: [
    { label: 'Append (us)', data: props.history.map(s => safeNum(s.wal?.avg_append_latency_us)), borderColor: '#8b5cf6' },
    { label: 'Fsync (us)', data: props.history.map(s => safeNum(s.wal?.avg_fsync_latency_us)), borderColor: '#f97316' },
    { label: 'Flush (us)', data: props.history.map(s => safeNum(s.wal?.avg_flush_latency_us)), borderColor: '#06b6d4' },
  ],
}))

const latencyIndexChart = computed(() => ({
  labels: labels.value,
  datasets: [
    { label: 'Insert (us)', data: props.history.map(s => safeNum(s.index?.avg_insert_latency_us)), borderColor: '#22c55e' },
    { label: 'Search (us)', data: props.history.map(s => safeNum(s.index?.avg_search_latency_us)), borderColor: '#3b82f6' },
    { label: 'Flush (us)', data: props.history.map(s => safeNum(s.index?.avg_flush_latency_us)), borderColor: '#06b6d4' },
  ],
}))

const latencyVlogChart = computed(() => ({
  labels: labels.value,
  datasets: [
    { label: 'Read (us)', data: props.history.map(s => safeNum(s.vlog?.avg_read_latency_us)), borderColor: '#3b82f6' },
    { label: 'Write (us)', data: props.history.map(s => safeNum(s.vlog?.avg_write_latency_us)), borderColor: '#22c55e' },
    { label: 'Flush (us)', data: props.history.map(s => safeNum(s.vlog?.avg_flush_latency_us)), borderColor: '#06b6d4' },
  ],
}))

function safeNum(v) {
  return (v == null || isNaN(v)) ? 0 : v
}
</script>

<template>
  <div v-if="!history || history.length === 0" class="text-slate-400 text-sm p-4">
    No stats history available. Stats are recorded every 60 seconds.
  </div>

  <template v-else>
    <template v-if="mode === 'overview'">
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
          <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">Operations</h3>
          <div class="h-56"><Line :data="overviewOpsChart" :options="chartOptions" /></div>
        </div>
        <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
          <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">Latency</h3>
          <div class="h-56"><Line :data="overviewLatencyChart" :options="chartOptions" /></div>
        </div>
      </div>
    </template>

    <template v-if="mode === 'ops'">
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
          <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">Database Operations</h3>
          <div class="h-56"><Line :data="opsDbChart" :options="chartOptions" /></div>
        </div>
        <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
          <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">WAL Operations</h3>
          <div class="h-56"><Line :data="opsWalChart" :options="chartOptions" /></div>
        </div>
        <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
          <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">Index Operations</h3>
          <div class="h-56"><Line :data="opsIndexChart" :options="chartOptions" /></div>
        </div>
        <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
          <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">VLog Operations</h3>
          <div class="h-56"><Line :data="opsVlogChart" :options="chartOptions" /></div>
        </div>
      </div>
    </template>

    <template v-if="mode === 'latency'">
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
          <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">DB Latency</h3>
          <div class="h-56"><Line :data="latencyDbChart" :options="chartOptions" /></div>
        </div>
        <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
          <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">WAL Latency</h3>
          <div class="h-56"><Line :data="latencyWalChart" :options="chartOptions" /></div>
        </div>
        <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
          <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">Index Latency</h3>
          <div class="h-56"><Line :data="latencyIndexChart" :options="chartOptions" /></div>
        </div>
        <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
          <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">VLog Latency</h3>
          <div class="h-56"><Line :data="latencyVlogChart" :options="chartOptions" /></div>
        </div>
      </div>
    </template>
  </template>
</template>
