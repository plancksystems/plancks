<script setup>
import { ref, watch, onMounted, onUnmounted } from 'vue'
import { fetchServiceStats, fetchMonitorData } from '../api'
import StatsCharts from './StatsCharts.vue'
import KpiCards from './KpiCards.vue'
import VlogTable from './VlogTable.vue'
import { Activity, RefreshCw } from 'lucide-vue-next'

const props = defineProps({
  serviceName: { type: String, required: true },
  serviceInfo: { type: Object, default: null },
})

const statsHistory = ref([])
const currentStats = ref(null)
const vlogs = ref([])
const loading = ref(true)
const error = ref(null)
const activeTab = ref('overview')
let refreshInterval = null

const tabs = [
  { key: 'overview', label: 'Overview' },
  { key: 'ops', label: 'Operations' },
  { key: 'latency', label: 'Latency' },
  { key: 'vlogs', label: 'VLogs' },
]

async function loadStats() {
  loading.value = true
  error.value = null
  statsHistory.value = []
  currentStats.value = null
  vlogs.value = []
  try {
    if (props.serviceInfo?.status === 'running') {
      const data = await fetchMonitorData(props.serviceName)
      const history = data.history || []
      currentStats.value = data.current || null
      if (currentStats.value) {
        history.push({ ts: Date.now(), ...currentStats.value })
      }
      statsHistory.value = history
      vlogs.value = data.vlogs || []
    }
  } catch {
    try {
      const snapshots = await fetchServiceStats(props.serviceName, 60)
      statsHistory.value = snapshots
      if (snapshots.length > 0) currentStats.value = snapshots[snapshots.length - 1]
    } catch {  }
  } finally {
    loading.value = false
  }
}

watch(() => props.serviceName, () => { loadStats() })

onMounted(() => {
  loadStats()
  refreshInterval = setInterval(loadStats, 30000)
})

onUnmounted(() => {
  if (refreshInterval) clearInterval(refreshInterval)
})
</script>

<template>
  <div class="flex-1 flex flex-col bg-white min-w-0 overflow-hidden">
    <div class="bg-slate-100 border-b border-slate-200 flex items-center px-4 py-2 shrink-0">
      <Activity :size="16" class="text-green-500 mr-2" />
      <span class="text-sm font-medium text-slate-700">{{ serviceName }}</span>
      <span class="text-xs text-slate-400 ml-2">Dashboard</span>
      <button class="ml-auto px-2 py-1 text-xs text-slate-600 hover:bg-slate-200 rounded flex items-center gap-1" @click="loadStats">
        <RefreshCw :size="12" :class="{ 'animate-spin': loading }" /> Refresh
      </button>
    </div>

    <div v-if="error" class="px-4 py-2 bg-red-50 border-b border-red-200 text-xs text-red-600">{{ error }}</div>

    <div class="flex-1 overflow-y-auto p-4 light-scroll">
      <div class="flex items-center gap-2 mb-3">
        <div class="flex-1 h-px bg-slate-200" />
        <div class="flex gap-1">
          <button
            v-for="tab in tabs"
            :key="tab.key"
            class="px-2 py-1 text-[10px] font-medium rounded"
            :class="activeTab === tab.key
              ? 'bg-blue-100 text-blue-700'
              : 'text-slate-500 hover:bg-slate-100'"
            @click="activeTab = tab.key"
          >{{ tab.label }}</button>
        </div>
      </div>

      <div v-if="loading" class="text-xs text-slate-400 py-8 text-center">Loading stats...</div>

      <template v-else>
        <template v-if="activeTab === 'overview'">
          <KpiCards :current="currentStats" :vlogs="vlogs" />
          <StatsCharts :history="statsHistory" mode="overview" class="mt-4" />
        </template>
        <template v-else-if="activeTab === 'ops'">
          <StatsCharts :history="statsHistory" mode="ops" />
        </template>
        <template v-else-if="activeTab === 'latency'">
          <StatsCharts :history="statsHistory" mode="latency" />
        </template>
        <template v-else-if="activeTab === 'vlogs'">
          <VlogTable :vlogs="vlogs" :gc-dead-ratio="30" />
        </template>
      </template>

      <div v-if="!loading && !statsHistory.length && !currentStats" class="text-center py-8">
        <p class="text-xs text-slate-400">No stats data available yet. Stats are collected every minute.</p>
      </div>
    </div>
  </div>
</template>
