<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { fetchMonitorData, getConfig } from '../api'
import StatsCharts from './StatsCharts.vue'
import VlogTable from './VlogTable.vue'
import KpiCards from './KpiCards.vue'
import HttpStatsPanel from './HttpStatsPanel.vue'
import WasmStatsPanel from './WasmStatsPanel.vue'

const props = defineProps({
  selectedDb: Number,
})

const statsHistory = ref([])
const currentStats = ref(null)
const vlogs = ref([])
const loading = ref(true)
const error = ref(null)
const activeTab = ref('overview')
const gcDeadRatio = ref(30)
let refreshInterval = null

async function loadData() {
  error.value = null
  try {
    const data = await fetchMonitorData(props.selectedDb)
    currentStats.value = data.current
    vlogs.value = data.vlogs
    const history = data.history || []
    if (currentStats.value) {
      history.push({ ts: Date.now(), ...currentStats.value })
    }
    statsHistory.value = history
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

async function loadGcConfig() {
  try {
    const data = await getConfig(props.selectedDb)
    if (data.config?.gc?.dead_ratio != null) {
      gcDeadRatio.value = data.config.gc.dead_ratio
    }
  } catch (_) {  }
}

onMounted(() => {
  loadData()
  loadGcConfig()
  refreshInterval = setInterval(loadData, 60000)
})

onUnmounted(() => {
  if (refreshInterval) clearInterval(refreshInterval)
})

const tabs = [
  { key: 'overview', label: 'Overview' },
  { key: 'ops', label: 'Operations' },
  { key: 'latency', label: 'Latency' },
  { key: 'vlogs', label: 'VLogs' },
  { key: 'http-stats', label: 'HTTP Stats' },
  { key: 'wasm-stats', label: 'WASM Stats' },
]
</script>

<template>
  <div class="flex-1 flex flex-col overflow-hidden bg-white min-h-0 min-w-0">
    <div class="bg-slate-100 border-b border-slate-200 flex items-center px-3 gap-1">
      <button
        v-for="tab in tabs"
        :key="tab.key"
        class="px-3 py-1.5 text-xs font-medium rounded-t transition"
        :class="activeTab === tab.key
          ? 'bg-white text-blue-600 border border-b-0 border-slate-200 -mb-px'
          : 'text-slate-500 hover:text-slate-700'"
        @click="activeTab = tab.key"
      >
        {{ tab.label }}
      </button>
      <div class="ml-auto flex items-center gap-2">
        <button
          class="px-2 py-1 text-xs text-slate-500 hover:text-slate-700 rounded hover:bg-slate-200"
          @click="loading = true; loadData()"
        >
          &#8635; Refresh
        </button>
        <span v-if="loading" class="text-xs text-slate-400">Loading...</span>
      </div>
    </div>

    <div class="flex-1 overflow-y-auto p-4 light-scroll min-h-0">
      <div v-if="error" class="text-red-600 text-sm p-4">{{ error }}</div>

      <template v-else-if="activeTab === 'overview'">
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
        <VlogTable :vlogs="vlogs" :gc-dead-ratio="gcDeadRatio" />
      </template>

      <template v-else-if="activeTab === 'http-stats'">
        <HttpStatsPanel :selected-db="selectedDb" />
      </template>

      <template v-else-if="activeTab === 'wasm-stats'">
        <WasmStatsPanel :selected-db="selectedDb" />
      </template>

    </div>
  </div>
</template>
