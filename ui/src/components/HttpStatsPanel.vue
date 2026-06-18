<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { fetchMonitorData } from '../api'

const props = defineProps({
  selectedDb: Number,
  serviceName: { type: String, default: null },
})

const httpStats = ref(null)
const loading = ref(true)
const autoRefresh = ref(10)
let refreshTimer = null

const methods = ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS']

async function loadStats() {
  try {
    const svc = props.serviceName || props.selectedDb
    if (!svc && svc !== 0) { loading.value = false; return }
    const data = await fetchMonitorData(svc)
    if (data.current?.http) {
      httpStats.value = data.current.http
    } else {
      httpStats.value = null
    }
  } catch (_) {  }
  loading.value = false
}

import { watch } from 'vue'
watch(() => props.serviceName, () => { loading.value = true; loadStats() })

const methodRows = computed(() => {
  if (!httpStats.value) return []
  return methods
    .filter(m => httpStats.value[m])
    .map(m => {
      const s = httpStats.value[m]
      return {
        method: m,
        count: s.count || 0,
        avg_ms: ((s.avg_latency_us || 0) / 1_000).toFixed(2),
      }
    })
})

const totalRequests = computed(() => httpStats.value?.total_requests || 0)

const maxCount = computed(() => {
  if (!methodRows.value.length) return 1
  return Math.max(...methodRows.value.map(r => r.count))
})

function startAutoRefresh() {
  if (refreshTimer) clearInterval(refreshTimer)
  if (autoRefresh.value > 0) {
    refreshTimer = setInterval(loadStats, autoRefresh.value * 1000)
  }
}

onMounted(() => {
  loadStats()
  startAutoRefresh()
})

onUnmounted(() => {
  if (refreshTimer) clearInterval(refreshTimer)
})
</script>

<template>
  <div class="space-y-4">
    <div class="flex items-center justify-between">
      <h3 class="text-sm font-semibold text-slate-700">HTTP Metrics</h3>
      <div class="flex items-center gap-2">
        <label class="text-xs text-slate-500">Auto-refresh:</label>
        <select v-model.number="autoRefresh" @change="startAutoRefresh" class="text-xs border rounded px-1 py-0.5">
          <option :value="5">5s</option>
          <option :value="10">10s</option>
          <option :value="30">30s</option>
          <option :value="0">Off</option>
        </select>
      </div>
    </div>

    <div v-if="loading" class="text-xs text-slate-400">Loading...</div>
    <div v-else-if="!httpStats" class="text-xs text-slate-400">No HTTP metrics available</div>

    <template v-else>
      <div class="text-sm text-slate-600 mb-3">
        Total Requests: <span class="font-semibold text-slate-800">{{ totalRequests.toLocaleString() }}</span>
      </div>

      <table class="w-full text-xs border-collapse">
        <thead>
          <tr class="border-b border-slate-200 text-left text-slate-500">
            <th class="py-1.5 px-2 font-medium">Method</th>
            <th class="py-1.5 px-2 font-medium text-right">Count</th>
            <th class="py-1.5 px-2 font-medium text-right">Avg (ms)</th>
            <th class="py-1.5 px-2 font-medium w-32">Distribution</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="row in methodRows" :key="row.method" class="border-b border-slate-100 hover:bg-slate-50">
            <td class="py-1.5 px-2 font-mono font-medium text-slate-700">{{ row.method }}</td>
            <td class="py-1.5 px-2 text-right text-slate-600">{{ row.count.toLocaleString() }}</td>
            <td class="py-1.5 px-2 text-right text-slate-600">{{ row.avg_ms }}</td>
            <td class="py-1.5 px-2">
              <div class="h-3 bg-slate-100 rounded overflow-hidden">
                <div
                  class="h-full bg-blue-400 rounded"
                  :style="{ width: (row.count / maxCount * 100) + '%' }"
                ></div>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </template>
  </div>
</template>
