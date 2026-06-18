<script setup>
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
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
import { fetchServices, fetchMonitorData, fetchApps } from '../api'
import { Activity, Pause, Play, Server, Cpu, MemoryStick, BookOpen, PenLine, Timer, HardDrive, Database, ChevronDown, ChevronRight, RefreshCw, Globe, Box, FileText } from 'lucide-vue-next'
import HttpStatsPanel from './HttpStatsPanel.vue'
import WasmStatsPanel from './WasmStatsPanel.vue'
import LogViewer from './LogViewer.vue'

ChartJS.register(CategoryScale, LinearScale, PointElement, LineElement, Title, Tooltip, Legend, Filler)

const SERVICE_COLORS = [
  '#3b82f6', '#22c55e', '#ef4444', '#f59e0b', '#8b5cf6',
  '#06b6d4', '#ec4899', '#f97316', '#14b8a6', '#a855f7',
  '#64748b', '#dc2626',
]

const services = ref([])
const apps = ref([])
const allStats = ref({})
const loading = ref(true)
const error = ref(null)
const activeTab = ref('cpu')
const timeRange = ref('5m')
const paused = ref(false)
const enabledServices = ref(new Set())
let refreshInterval = null

const logFiles = ref({})
const logExpandedService = ref(null)
const logSelectedService = ref(null)
const logSelectedFile = ref(null)

const httpSelectedService = ref(null)
const wasmSelectedService = ref(null)

const isLogsTab = computed(() => activeTab.value === 'logs')
const isServiceSelectTab = computed(() => ['logs', 'http-stats', 'wasm-stats'].includes(activeTab.value))

async function loadLogFiles(serviceName) {
  try {
    const resp = await fetch(`/api/logs?service=${encodeURIComponent(serviceName)}`)
    const data = await resp.json()
    if (data.success && data.files) {
      logFiles.value[serviceName] = data.files.sort((a, b) => b.modified - a.modified)
    }
  } catch (_) {  }
}

function toggleLogService(svcName) {
  if (logExpandedService.value === svcName) {
    logExpandedService.value = null
  } else {
    logExpandedService.value = svcName
    logSelectedService.value = svcName
    if (!logFiles.value[svcName]) {
      loadLogFiles(svcName)
    }
  }
}

function selectLogFile(svcName, fileName) {
  logSelectedService.value = svcName
  logSelectedFile.value = fileName
}

function formatFileSize(bytes) {
  if (bytes < 1024) return bytes + ' B'
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB'
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB'
}

const tabs = [
  { key: 'cpu', label: 'CPU', icon: Cpu },
  { key: 'memory', label: 'Memory', icon: MemoryStick },
  { key: 'reads', label: 'Reads', icon: BookOpen },
  { key: 'writes', label: 'Writes', icon: PenLine },
  { key: 'latency', label: 'Latency', icon: Timer },
  { key: 'storage', label: 'Storage', icon: HardDrive },
  { key: 'vlogs', label: 'VLogs', icon: Database },
  { key: 'http-stats', label: 'HTTP Stats', icon: Globe },
  { key: 'wasm-stats', label: 'WASM Stats', icon: Box },
  { key: 'logs', label: 'Logs', icon: FileText },
]

const timeRanges = [
  { key: '5m', label: '5m', minutes: 5 },
  { key: '15m', label: '15m', minutes: 15 },
  { key: '1h', label: '1h', minutes: 60 },
  { key: '3h', label: '3h', minutes: 180 },
  { key: '5h', label: '5h', minutes: 300 },
]

const runningServices = computed(() => services.value.filter(s => s.status === 'running'))
const stoppedServices = computed(() => services.value.filter(s => s.status !== 'running'))

function groupByApp(svcList) {
  const groups = []
  for (const app of apps.value) {
    const own = (app.services || [])
      .map(s => svcList.find(ls => ls.name === s.name))
      .filter(Boolean)
    if (own.length > 0) {
      groups.push({ name: app.name, kind: app.kind, services: own })
    }
  }
  return groups
}

const runningByApp = computed(() => groupByApp(runningServices.value))
const stoppedByApp = computed(() => groupByApp(stoppedServices.value))
const allByApp = computed(() => groupByApp(services.value))

const visibleServiceNames = computed(() =>
  runningServices.value.filter(s => enabledServices.value.has(s.name)).map(s => s.name)
)

const hasData = computed(() =>
  visibleServiceNames.value.some(n => (allStats.value[n]?.history?.length || 0) > 0)
)

function colorFor(serviceName) {
  const idx = runningServices.value.findIndex(s => s.name === serviceName)
  return SERVICE_COLORS[(idx >= 0 ? idx : 0) % SERVICE_COLORS.length]
}

function colorAlpha(hex, alpha) {
  return hex + Math.round(alpha * 255).toString(16).padStart(2, '0')
}

function toggleService(name) {
  const s = enabledServices.value
  if (s.has(name)) s.delete(name)
  else s.add(name)
  enabledServices.value = new Set(s)
}

function selectAll() {
  enabledServices.value = new Set(runningServices.value.map(s => s.name))
}

function deselectAll() {
  enabledServices.value = new Set()
}

function filterByTimeRange(history) {
  const range = timeRanges.find(r => r.key === timeRange.value)
  if (!range) return history
  const cutoff = Date.now() - range.minutes * 60 * 1000
  return history.filter(s => s.ts >= cutoff)
}

const unifiedTimestamps = computed(() => {
  const tsSet = new Set()
  for (const name of visibleServiceNames.value) {
    for (const s of filterByTimeRange(allStats.value[name]?.history || [])) {
      if (s.ts) tsSet.add(s.ts)
    }
  }
  return [...tsSet].sort()
})

const unifiedLabels = computed(() =>
  unifiedTimestamps.value.map(ts => {
    const d = new Date(ts)
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
  })
)

function alignToTimestamps(history, timestamps) {
  const map = new Map()
  for (const s of history) {
    if (s.ts) map.set(s.ts, s)
  }
  return timestamps.map(ts => map.get(ts) || null)
}

function safeNum(v) {
  return (v == null || isNaN(v)) ? 0 : v
}

function multiServiceDataset(metricFn) {
  const ts = unifiedTimestamps.value
  return visibleServiceNames.value.map(name => {
    const history = filterByTimeRange(allStats.value[name]?.history || [])
    const aligned = alignToTimestamps(history, ts)
    const color = colorFor(name)
    return {
      label: name,
      data: aligned.map(s => s ? safeNum(metricFn(s)) : null),
      borderColor: color,
      backgroundColor: colorAlpha(color, 0.08),
      spanGaps: true,
    }
  })
}

const chartOptions = {
  responsive: true,
  maintainAspectRatio: false,
  animation: { duration: 300 },
  interaction: { mode: 'index', intersect: false },
  plugins: {
    legend: { display: false },
    tooltip: { bodyFont: { size: 11 } },
  },
  scales: {
    x: { ticks: { font: { size: 10 }, maxRotation: 45, maxTicksLimit: 20 } },
    y: { beginAtZero: true, ticks: { font: { size: 10 } } },
  },
  elements: {
    point: { radius: 1.5, hoverRadius: 4 },
    line: { tension: 0.3, borderWidth: 2 },
  },
}

const readsChart = computed(() => ({
  labels: unifiedLabels.value,
  datasets: multiServiceDataset(s => s.db?.total_reads || 0),
}))

const writesChart = computed(() => ({
  labels: unifiedLabels.value,
  datasets: multiServiceDataset(s => s.db?.total_writes || 0),
}))

const readLatencyChart = computed(() => ({
  labels: unifiedLabels.value,
  datasets: multiServiceDataset(s => s.db?.avg_read_latency_us || 0),
}))

const writeLatencyChart = computed(() => ({
  labels: unifiedLabels.value,
  datasets: multiServiceDataset(s => s.db?.avg_write_latency_us || 0),
}))

const walFsyncChart = computed(() => ({
  labels: unifiedLabels.value,
  datasets: multiServiceDataset(s => s.wal?.avg_fsync_latency_us || 0),
}))

const storageChart = computed(() => ({
  labels: unifiedLabels.value,
  datasets: multiServiceDataset(s =>
    ((s.vlog?.total_bytes_written || 0) + (s.wal?.total_bytes_written || 0)) / (1024 * 1024)
  ),
}))

const processStats = ref({})

const processTimestamps = computed(() => {
  const tsSet = new Set()
  for (const name of visibleServiceNames.value) {
    for (const s of filterByTimeRange(processStats.value[name] || [])) {
      if (s.ts) tsSet.add(s.ts)
    }
  }
  return [...tsSet].sort()
})

const processLabels = computed(() =>
  processTimestamps.value.map(ts => {
    const d = new Date(ts)
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
  })
)

function processDataset(metricFn) {
  const ts = processTimestamps.value
  return visibleServiceNames.value.map(name => {
    const history = filterByTimeRange(processStats.value[name] || [])
    const map = new Map()
    for (const s of history) { if (s.ts) map.set(s.ts, s) }
    const aligned = ts.map(t => map.get(t) || null)
    const color = colorFor(name)
    return {
      label: name,
      data: aligned.map(s => s ? safeNum(metricFn(s)) : null),
      borderColor: color,
      backgroundColor: colorAlpha(color, 0.08),
      spanGaps: true,
    }
  })
}

const cpuChart = computed(() => ({
  labels: processLabels.value,
  datasets: processDataset(s => s.cpu_percent || 0),
}))

const memoryChart = computed(() => ({
  labels: processLabels.value,
  datasets: processDataset(s => s.rss_mb || 0),
}))

const allVlogs = ref({})
const vlogExpanded = ref(new Set())

function toggleVlogGroup(name) {
  if (vlogExpanded.value.has(name)) vlogExpanded.value.delete(name)
  else vlogExpanded.value.add(name)
  vlogExpanded.value = new Set(vlogExpanded.value)
}

const vlogGrouped = computed(() => {
  return visibleServiceNames.value
    .map(name => {
      const vlogs = (allVlogs.value[name] || []).sort((a, b) => (a.vlog_id || 0) - (b.vlog_id || 0))
      const totals = { count: 0, deleted: 0, total_bytes: 0, live_bytes: 0, dead_bytes: 0 }
      for (const v of vlogs) {
        totals.count += v.count || 0
        totals.deleted += v.deleted || 0
        totals.total_bytes += v.total_bytes || 0
        totals.live_bytes += v.live_bytes || 0
        totals.dead_bytes += v.dead_bytes || 0
      }
      return { name, vlogs, totals }
    })
    .filter(g => g.vlogs.length > 0)
})

function fmtBytes(b) {
  if (b == null || b === 0) return '0 B'
  if (b >= 1073741824) return (b / 1073741824).toFixed(2) + ' GB'
  if (b >= 1048576) return (b / 1048576).toFixed(1) + ' MB'
  if (b >= 1024) return (b / 1024).toFixed(1) + ' KB'
  return b + ' B'
}

function ratioBarWidth(ratio) { return Math.min(ratio * 100, 100) + '%' }
function ratioBarColor(ratio) {
  if (ratio >= 0.7) return 'bg-red-500'
  if (ratio >= 0.4) return 'bg-orange-400'
  return 'bg-green-500'
}
function ratioClass(ratio) {
  if (ratio >= 0.7) return 'text-red-600 font-semibold'
  if (ratio >= 0.4) return 'text-orange-600'
  return 'text-slate-700'
}

const MAX_HISTORY = 3600

const prevCpuTime = {}

async function loadAll() {
  if (paused.value) return
  error.value = null
  try {
    const [svcs, appList] = await Promise.all([fetchServices(), fetchApps()])
    services.value = svcs
    apps.value = appList
    for (const svc of runningServices.value) {
      if (!enabledServices.value.has(svc.name)) {
        enabledServices.value.add(svc.name)
      }
    }
    enabledServices.value = new Set(enabledServices.value)

    const running = runningServices.value
    const now = Date.now()
    const newStats = { ...allStats.value }
    const newPstats = { ...processStats.value }
    const newVlogs = {}

    const results = await Promise.allSettled(
      running.map(svc => fetchMonitorData(svc.name).then(data => ({ name: svc.name, data })))
    )

    for (const r of results) {
      if (r.status !== 'fulfilled') continue
      const { name, data } = r.value

      const prevHistory = newStats[name]?.history || []
      if (data.current && Object.keys(data.current).length > 0) {
        prevHistory.push({ ts: now, ...data.current })
        if (prevHistory.length > MAX_HISTORY) prevHistory.splice(0, prevHistory.length - MAX_HISTORY)
      }
      newStats[name] = { history: prevHistory, current: data.current || null }

      let cpuPct = 0
      if (data.cpu_time_us != null && prevCpuTime[name]) {
        const dtMs = now - prevCpuTime[name].ts
        const dCpu = data.cpu_time_us - prevCpuTime[name].val
        if (dtMs > 0 && dCpu >= 0) {
          cpuPct = (dCpu / (dtMs * 1000)) * 100
        }
      }
      if (data.cpu_time_us != null) {
        prevCpuTime[name] = { ts: now, val: data.cpu_time_us }
      }

      const prevProcess = newPstats[name] || []
      prevProcess.push({ ts: now, cpu_percent: cpuPct, rss_mb: data.rss_mb || 0 })
      if (prevProcess.length > MAX_HISTORY) prevProcess.splice(0, prevProcess.length - MAX_HISTORY)
      newPstats[name] = prevProcess

      if (data.vlogs) newVlogs[name] = data.vlogs
    }

    allStats.value = newStats
    processStats.value = newPstats
    allVlogs.value = newVlogs
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

function togglePause() {
  paused.value = !paused.value
}

function startRefresh() {
  if (refreshInterval) clearInterval(refreshInterval)
  refreshInterval = setInterval(loadAll, 5000)
}

onMounted(() => {
  loadAll()
  startRefresh()
})

onUnmounted(() => {
  if (refreshInterval) clearInterval(refreshInterval)
})
</script>

<template>
  <div class="flex-1 flex flex-col bg-white min-w-0 overflow-hidden">
    <div class="bg-slate-100 border-b border-slate-200 flex items-center px-4 py-2 shrink-0">
      <Activity :size="16" class="text-green-500 mr-2" />
      <span class="text-sm font-medium text-slate-700">Dashboard</span>
      <span class="text-xs text-slate-400 ml-2">{{ runningServices.length }}/{{ services.length }} services</span>

      <div class="ml-auto flex items-center gap-2">
        <div class="flex gap-0.5 bg-slate-200/60 rounded p-0.5">
          <button
            v-for="tr in timeRanges"
            :key="tr.key"
            class="px-2 py-0.5 text-[10px] font-medium rounded transition-colors"
            :class="timeRange === tr.key
              ? 'bg-white text-blue-700 shadow-sm'
              : 'text-slate-500 hover:text-slate-700'"
            @click="timeRange = tr.key"
          >{{ tr.label }}</button>
        </div>

        <button
          class="p-1 rounded text-slate-500 hover:bg-slate-200 transition-colors"
          :title="paused ? 'Resume auto-refresh' : 'Pause auto-refresh'"
          @click="togglePause"
        >
          <Pause v-if="!paused" :size="13" />
          <Play v-else :size="13" />
        </button>

        <span v-if="paused" class="text-[10px] text-amber-600 font-medium">Paused</span>
      </div>
    </div>

    <div v-if="error" class="px-4 py-2 bg-red-50 border-b border-red-200 text-xs text-red-600">{{ error }}</div>

    <div class="flex-1 flex min-h-0">
      <aside class="w-48 min-w-[12rem] max-w-[12rem] bg-slate-50 border-r border-slate-200 flex flex-col overflow-hidden">
        <div class="px-3 pt-3 pb-1 flex items-center justify-between">
          <span class="text-[10px] font-semibold text-slate-400 uppercase tracking-wider">Services</span>
          <div v-if="!isServiceSelectTab" class="flex gap-1">
            <button class="text-[9px] text-blue-600 hover:text-blue-700" @click="selectAll">All</button>
            <span class="text-[9px] text-slate-300">|</span>
            <button class="text-[9px] text-blue-600 hover:text-blue-700" @click="deselectAll">None</button>
          </div>
        </div>

        <div class="flex-1 overflow-y-auto light-scroll px-2 pb-2">
          <template v-if="!isServiceSelectTab">
            <template v-if="runningServices.length > 0">
              <div class="text-[9px] text-slate-400 uppercase tracking-wider px-1 pt-2 pb-1">Running</div>
              <template v-for="grp in runningByApp" :key="'r:' + grp.name">
                <div class="text-[10px] font-semibold text-slate-500 px-1 pt-2 pb-0.5">{{ grp.name }}</div>
                <div
                  v-for="svc in grp.services"
                  :key="svc.name"
                  class="flex items-center gap-1.5 pl-3 pr-1.5 py-1 rounded cursor-pointer hover:bg-slate-200/70 select-none"
                  :class="{ 'opacity-40': !enabledServices.has(svc.name) }"
                  @click="toggleService(svc.name)"
                >
                  <span
                    class="w-2.5 h-2.5 rounded-sm shrink-0 border"
                    :style="{
                      backgroundColor: enabledServices.has(svc.name) ? colorFor(svc.name) : 'transparent',
                      borderColor: colorFor(svc.name),
                    }"
                  />
                  <span class="text-[11px] text-slate-700 font-medium truncate">{{ svc.name }}</span>
                </div>
              </template>
            </template>
            <template v-if="stoppedServices.length > 0">
              <div class="text-[9px] text-slate-400 uppercase tracking-wider px-1 pt-3 pb-1">Stopped</div>
              <template v-for="grp in stoppedByApp" :key="'s:' + grp.name">
                <div class="text-[10px] font-semibold text-slate-400 px-1 pt-2 pb-0.5">{{ grp.name }}</div>
                <div
                  v-for="svc in grp.services"
                  :key="svc.name"
                  class="flex items-center gap-1.5 pl-3 pr-1.5 py-1 rounded select-none opacity-40"
                >
                  <span class="w-2.5 h-2.5 rounded-sm shrink-0 border border-slate-300 bg-transparent" />
                  <span class="text-[11px] text-slate-500 truncate">{{ svc.name }}</span>
                </div>
              </template>
            </template>
          </template>

          <template v-else-if="activeTab === 'http-stats' || activeTab === 'wasm-stats'">
            <template v-for="grp in allByApp" :key="'st:' + grp.name">
              <div class="text-[10px] font-semibold text-slate-500 px-1 pt-2 pb-0.5">{{ grp.name }}</div>
              <div
                v-for="svc in grp.services"
                :key="svc.name"
                class="flex items-center gap-1.5 pl-3 pr-1.5 py-1.5 rounded cursor-pointer hover:bg-slate-200/70 select-none transition-colors"
                :class="(activeTab === 'http-stats' ? httpSelectedService : wasmSelectedService) === svc.name
                  ? 'bg-blue-50 text-blue-700'
                  : ''"
                @click="activeTab === 'http-stats' ? (httpSelectedService = svc.name) : (wasmSelectedService = svc.name)"
              >
                <span
                  class="w-2 h-2 rounded-full shrink-0"
                  :class="svc.status === 'running' ? 'bg-green-500' : 'bg-slate-300'"
                />
                <span
                  class="text-[11px] font-medium truncate"
                  :class="(activeTab === 'http-stats' ? httpSelectedService : wasmSelectedService) === svc.name
                    ? 'text-blue-700'
                    : 'text-slate-700'"
                >{{ svc.name }}</span>
              </div>
            </template>
          </template>

          <template v-else>
            <template v-for="grp in allByApp" :key="'lg:' + grp.name">
              <div class="text-[10px] font-semibold text-slate-500 px-1 pt-2 pb-0.5">{{ grp.name }}</div>
              <div
                v-for="svc in grp.services"
                :key="svc.name"
                class="text-xs pl-2"
              >
                <button
                  class="w-full text-left px-1.5 py-1 rounded flex items-center gap-1.5 hover:bg-slate-200/70 transition-colors"
                  :class="logExpandedService === svc.name ? 'bg-slate-200/50' : ''"
                  @click="toggleLogService(svc.name)"
                >
                  <span class="text-[10px] text-slate-400 w-3">{{ logExpandedService === svc.name ? '&#9660;' : '&#9654;' }}</span>
                  <span
                    class="w-2 h-2 rounded-full shrink-0"
                    :class="svc.status === 'running' ? 'bg-green-500' : 'bg-slate-300'"
                  />
                  <span class="text-[11px] text-slate-700 font-medium truncate">{{ svc.name }}</span>
                </button>

                <div v-if="logExpandedService === svc.name && logFiles[svc.name]" class="pl-6 pb-1">
                  <div v-if="logFiles[svc.name].length === 0" class="text-[10px] text-slate-400 py-0.5 px-1">No log files</div>
                  <button
                    v-for="f in logFiles[svc.name]"
                    :key="f.name"
                    class="w-full text-left px-1.5 py-0.5 rounded text-[10px] truncate hover:bg-slate-200/70 transition-colors"
                    :class="logSelectedService === svc.name && logSelectedFile === f.name
                      ? 'text-blue-600 bg-blue-50 font-medium'
                      : 'text-slate-500'"
                    :title="`${f.name} (${formatFileSize(f.size)})`"
                    @click="selectLogFile(svc.name, f.name)"
                  >
                    {{ f.name }}
                  </button>
                </div>
                <div v-else-if="logExpandedService === svc.name && !logFiles[svc.name]" class="pl-6">
                  <span class="text-[10px] text-slate-400">Loading...</span>
                </div>
              </div>
            </template>
          </template>

          <p v-if="services.length === 0" class="text-[10px] text-slate-400 px-1 py-2">No services</p>
        </div>
      </aside>

      <div class="flex-1 flex flex-col min-w-0 overflow-hidden">
        <div class="bg-slate-50 border-b border-slate-200 flex items-center px-3 py-1 shrink-0 gap-1">
          <button
            v-for="tab in tabs"
            :key="tab.key"
            class="flex items-center gap-1 px-2.5 py-1 text-[11px] font-medium rounded transition-colors"
            :class="activeTab === tab.key
              ? 'bg-blue-100 text-blue-700'
              : 'text-slate-500 hover:bg-slate-100 hover:text-slate-700'"
            @click="activeTab = tab.key"
          >
            <component :is="tab.icon" :size="12" />
            {{ tab.label }}
          </button>
        </div>

        <div class="flex-1 overflow-y-auto p-4 light-scroll">
          <div v-if="loading && !hasData" class="flex items-center justify-center h-full">
            <p class="text-xs text-slate-400">Loading stats...</p>
          </div>

          <template v-else-if="activeTab === 'cpu'">
            <template v-if="cpuChart.datasets.some(d => d.data.some(v => v !== null))">
              <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
                <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">CPU Usage (%)</h3>
                <div class="h-80"><Line :data="cpuChart" :options="chartOptions" /></div>
              </div>
            </template>
            <div v-else class="flex items-center justify-center h-full">
              <div class="text-center">
                <Cpu :size="32" class="mx-auto text-slate-300 mb-2" />
                <p class="text-sm text-slate-400">No CPU data yet</p>
                <p class="text-xs text-slate-400 mt-1">Metrics are collected every 60 seconds</p>
              </div>
            </div>
          </template>

          <template v-else-if="activeTab === 'memory'">
            <template v-if="memoryChart.datasets.some(d => d.data.some(v => v !== null))">
              <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
                <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">Memory Usage (MB)</h3>
                <div class="h-80"><Line :data="memoryChart" :options="chartOptions" /></div>
              </div>
            </template>
            <div v-else class="flex items-center justify-center h-full">
              <div class="text-center">
                <MemoryStick :size="32" class="mx-auto text-slate-300 mb-2" />
                <p class="text-sm text-slate-400">No memory data yet</p>
                <p class="text-xs text-slate-400 mt-1">Metrics are collected every 60 seconds</p>
              </div>
            </div>
          </template>

          <template v-else-if="activeTab === 'reads'">
            <template v-if="hasData">
              <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
                  <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">DB Reads</h3>
                  <div class="h-64"><Line :data="readsChart" :options="chartOptions" /></div>
                </div>
                <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
                  <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">Index Searches</h3>
                  <div class="h-64">
                    <Line
                      :data="{ labels: unifiedLabels, datasets: multiServiceDataset(s => s.index?.total_searches || 0) }"
                      :options="chartOptions"
                    />
                  </div>
                </div>
              </div>
            </template>
            <div v-else class="flex items-center justify-center h-full">
              <p class="text-xs text-slate-400">No read data available for selected services</p>
            </div>
          </template>

          <template v-else-if="activeTab === 'writes'">
            <template v-if="hasData">
              <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
                  <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">DB Writes</h3>
                  <div class="h-64"><Line :data="writesChart" :options="chartOptions" /></div>
                </div>
                <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
                  <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">WAL Appends</h3>
                  <div class="h-64">
                    <Line
                      :data="{ labels: unifiedLabels, datasets: multiServiceDataset(s => s.wal?.total_appends || 0) }"
                      :options="chartOptions"
                    />
                  </div>
                </div>
                <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
                  <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">Index Inserts</h3>
                  <div class="h-64">
                    <Line
                      :data="{ labels: unifiedLabels, datasets: multiServiceDataset(s => s.index?.total_inserts || 0) }"
                      :options="chartOptions"
                    />
                  </div>
                </div>
                <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
                  <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">VLog Writes</h3>
                  <div class="h-64">
                    <Line
                      :data="{ labels: unifiedLabels, datasets: multiServiceDataset(s => s.vlog?.total_writes || 0) }"
                      :options="chartOptions"
                    />
                  </div>
                </div>
              </div>
            </template>
            <div v-else class="flex items-center justify-center h-full">
              <p class="text-xs text-slate-400">No write data available for selected services</p>
            </div>
          </template>

          <template v-else-if="activeTab === 'latency'">
            <template v-if="hasData">
              <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
                  <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">Read Latency (μs)</h3>
                  <div class="h-64"><Line :data="readLatencyChart" :options="chartOptions" /></div>
                </div>
                <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
                  <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">Write Latency (μs)</h3>
                  <div class="h-64"><Line :data="writeLatencyChart" :options="chartOptions" /></div>
                </div>
                <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
                  <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">WAL Fsync Latency (μs)</h3>
                  <div class="h-64"><Line :data="walFsyncChart" :options="chartOptions" /></div>
                </div>
                <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
                  <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">Index Search Latency (μs)</h3>
                  <div class="h-64">
                    <Line
                      :data="{ labels: unifiedLabels, datasets: multiServiceDataset(s => s.index?.avg_search_latency_us || 0) }"
                      :options="chartOptions"
                    />
                  </div>
                </div>
              </div>
            </template>
            <div v-else class="flex items-center justify-center h-full">
              <p class="text-xs text-slate-400">No latency data available for selected services</p>
            </div>
          </template>

          <template v-else-if="activeTab === 'storage'">
            <template v-if="hasData">
              <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
                <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
                  <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">Total Bytes Written (MB)</h3>
                  <div class="h-64"><Line :data="storageChart" :options="chartOptions" /></div>
                </div>
                <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
                  <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">VLog Bytes Reclaimed</h3>
                  <div class="h-64">
                    <Line
                      :data="{ labels: unifiedLabels, datasets: multiServiceDataset(s => (s.vlog?.bytes_reclaimed || 0) / (1024 * 1024)) }"
                      :options="chartOptions"
                    />
                  </div>
                </div>
                <div class="bg-slate-50 rounded-lg border border-slate-200 p-3">
                  <h3 class="text-xs font-semibold text-slate-500 uppercase mb-2">GC Runs</h3>
                  <div class="h-64">
                    <Line
                      :data="{ labels: unifiedLabels, datasets: multiServiceDataset(s => s.vlog?.total_gc_runs || 0) }"
                      :options="chartOptions"
                    />
                  </div>
                </div>
              </div>
            </template>
            <div v-else class="flex items-center justify-center h-full">
              <p class="text-xs text-slate-400">No storage data available for selected services</p>
            </div>
          </template>

          <template v-else-if="activeTab === 'vlogs'">
            <div v-if="vlogGrouped.length === 0" class="flex items-center justify-center h-full">
              <div class="text-center">
                <Database :size="32" class="mx-auto text-slate-300 mb-2" />
                <p class="text-sm text-slate-400">No VLog data</p>
                <p class="text-xs text-slate-400 mt-1">VLog stats appear when services have active value logs</p>
              </div>
            </div>

            <div v-else class="space-y-1">
              <div v-for="group in vlogGrouped" :key="group.name">
                <div
                  class="flex items-center gap-2 px-3 py-2 rounded-lg cursor-pointer hover:bg-slate-50 transition-colors"
                  @click="toggleVlogGroup(group.name)"
                >
                  <component :is="vlogExpanded.has(group.name) ? ChevronDown : ChevronRight" :size="14" class="text-slate-400" />
                  <span class="w-2 h-2 rounded-full shrink-0" :style="{ backgroundColor: colorFor(group.name) }" />
                  <span class="text-sm font-medium text-slate-700">{{ group.name }}</span>
                  <span class="text-xs text-slate-400">({{ group.vlogs.length }} vlogs)</span>

                  <div class="ml-auto flex gap-4 text-[10px] text-slate-400">
                    <span>Entries: <strong class="text-slate-600">{{ group.totals.count.toLocaleString() }}</strong></span>
                    <span>Total: <strong class="text-purple-600">{{ fmtBytes(group.totals.total_bytes) }}</strong></span>
                    <span>Live: <strong class="text-green-600">{{ fmtBytes(group.totals.live_bytes) }}</strong></span>
                    <span>Dead: <strong :class="group.totals.dead_bytes > 0 ? 'text-orange-600' : 'text-slate-600'">{{ fmtBytes(group.totals.dead_bytes) }}</strong></span>
                  </div>
                </div>

                <div v-if="vlogExpanded.has(group.name)" class="ml-6 mb-3">
                  <div class="flex items-center gap-3 px-3 py-1.5 text-[10px] font-medium text-slate-400 uppercase tracking-wider border-b border-slate-100">
                    <span class="w-12">ID</span>
                    <span class="w-16 text-right">Entries</span>
                    <span class="w-16 text-right">Deleted</span>
                    <span class="w-16 text-right">Total</span>
                    <span class="w-16 text-right">Live</span>
                    <span class="w-16 text-right">Dead</span>
                    <span class="flex-1 min-w-[140px]">Dead Ratio</span>
                    <span class="w-10 text-center">Tail</span>
                  </div>

                  <div
                    v-for="v in group.vlogs" :key="v.vlog_id"
                    class="flex items-center gap-3 px-3 py-1.5 rounded hover:bg-slate-50 text-xs transition-colors"
                  >
                    <span class="w-12 font-mono text-slate-700">{{ v.vlog_id }}</span>
                    <span class="w-16 text-right text-slate-600">{{ (v.count || 0).toLocaleString() }}</span>
                    <span class="w-16 text-right text-slate-600">{{ (v.deleted || 0).toLocaleString() }}</span>
                    <span class="w-16 text-right text-slate-600">{{ fmtBytes(v.total_bytes) }}</span>
                    <span class="w-16 text-right text-green-700">{{ fmtBytes(v.live_bytes) }}</span>
                    <span class="w-16 text-right" :class="(v.dead_bytes || 0) > 0 ? 'text-orange-600' : 'text-slate-600'">{{ fmtBytes(v.dead_bytes) }}</span>
                    <div class="flex-1 min-w-[140px] flex items-center gap-2">
                      <div class="flex-1 h-2 bg-slate-200 rounded-full overflow-hidden">
                        <div
                          class="h-full rounded-full transition-all"
                          :class="ratioBarColor(v.dead_ratio || 0)"
                          :style="{ width: ratioBarWidth(v.dead_ratio || 0) }"
                        />
                      </div>
                      <span class="text-[10px] w-10 text-right" :class="ratioClass(v.dead_ratio || 0)">
                        {{ ((v.dead_ratio || 0) * 100).toFixed(1) }}%
                      </span>
                    </div>
                    <span class="w-10 text-center">
                      <span v-if="v.is_tail" class="inline-block w-2 h-2 rounded-full bg-green-500" title="Active tail" />
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </template>

          <template v-else-if="activeTab === 'http-stats'">
            <div v-if="!httpSelectedService" class="flex items-center justify-center h-full">
              <div class="text-center">
                <Globe :size="32" class="mx-auto text-slate-300 mb-2" />
                <p class="text-sm text-slate-400">Select a service to view HTTP stats</p>
              </div>
            </div>
            <HttpStatsPanel v-else :selected-db="0" :service-name="httpSelectedService" />
          </template>

          <template v-else-if="activeTab === 'wasm-stats'">
            <div v-if="!wasmSelectedService" class="flex items-center justify-center h-full">
              <div class="text-center">
                <Box :size="32" class="mx-auto text-slate-300 mb-2" />
                <p class="text-sm text-slate-400">Select a service to view WASM stats</p>
              </div>
            </div>
            <WasmStatsPanel v-else :selected-db="0" :service-name="wasmSelectedService" />
          </template>

          <template v-else-if="activeTab === 'logs'">
            <LogViewer :service="logSelectedService" :file="logSelectedFile" />
          </template>
        </div>
      </div>
    </div>
  </div>
</template>
