<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { fetchMonitorData } from '../api'

const props = defineProps({
  selectedDb: Number,
  serviceName: { type: String, default: null },
})

const wasmStats = ref(null)
const loading = ref(true)
const autoRefresh = ref(10)
let refreshTimer = null

async function loadStats() {
  try {
    const svc = props.serviceName || props.selectedDb
    if (!svc && svc !== 0) { loading.value = false; return }
    const data = await fetchMonitorData(svc)
    if (data.current?.wasm) {
      wasmStats.value = data.current.wasm
    } else {
      wasmStats.value = null
    }
  } catch (_) {  }
  loading.value = false
}

import { watch } from 'vue'
watch(() => props.serviceName, () => { loading.value = true; loadStats() })

const activePercent = computed(() => {
  if (!wasmStats.value || !wasmStats.value.max_instances) return 0
  return Math.round((wasmStats.value.active_instances / wasmStats.value.max_instances) * 100)
})

const poolPercent = computed(() => {
  if (!wasmStats.value || !wasmStats.value.max_instances) return 0
  return Math.round((wasmStats.value.pool_size / wasmStats.value.max_instances) * 100)
})

const instanceSlots = computed(() => {
  if (!wasmStats.value) return []
  const slots = []
  const active = wasmStats.value.active_instances || 0
  const pool = wasmStats.value.pool_size || 0
  const max = wasmStats.value.max_instances || 0
  for (let i = 0; i < max; i++) {
    if (i < active) slots.push('active')
    else if (i < pool) slots.push('idle')
    else slots.push('empty')
  }
  return slots
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
      <h3 class="text-sm font-semibold text-slate-700">WASM Instances</h3>
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
    <div v-else-if="!wasmStats" class="text-xs text-slate-400">No WASM metrics available</div>

    <template v-else>
      <div class="grid grid-cols-3 gap-3">
        <div class="border border-slate-200 rounded-lg p-3">
          <div class="text-xs text-slate-500 mb-1">Active</div>
          <div class="text-lg font-semibold text-slate-800">{{ wasmStats.active_instances }}</div>
          <div class="mt-1.5 h-2 bg-slate-100 rounded overflow-hidden">
            <div class="h-full bg-green-500 rounded" :style="{ width: activePercent + '%' }"></div>
          </div>
          <div class="text-[10px] text-slate-400 mt-0.5">{{ wasmStats.active_instances }} / {{ wasmStats.max_instances }} max</div>
        </div>

        <div class="border border-slate-200 rounded-lg p-3">
          <div class="text-xs text-slate-500 mb-1">Pool Size</div>
          <div class="text-lg font-semibold text-slate-800">{{ wasmStats.pool_size }}</div>
          <div class="mt-1.5 h-2 bg-slate-100 rounded overflow-hidden">
            <div class="h-full bg-blue-500 rounded" :style="{ width: poolPercent + '%' }"></div>
          </div>
          <div class="text-[10px] text-slate-400 mt-0.5">{{ wasmStats.pool_size }} / {{ wasmStats.max_instances }} max</div>
        </div>

        <div class="border border-slate-200 rounded-lg p-3">
          <div class="text-xs text-slate-500 mb-1">Recycled</div>
          <div class="text-lg font-semibold text-slate-800">{{ (wasmStats.total_instances_recycled || 0).toLocaleString() }}</div>
          <div class="text-[10px] text-slate-400 mt-1">total</div>
        </div>
      </div>

      <div class="text-xs text-slate-500">
        Config: min={{ wasmStats.min_instances }}, max={{ wasmStats.max_instances }}
      </div>

      <div class="text-sm text-slate-600 space-y-1">
        <div>Total Requests Processed: <span class="font-semibold text-slate-800">{{ (wasmStats.total_requests_processed || 0).toLocaleString() }}</span></div>
        <div>Avg Request Latency: <span class="font-semibold text-slate-800">{{ ((wasmStats.avg_request_latency_us || 0) / 1000).toFixed(2) }} ms</span></div>
      </div>

      <div class="border border-slate-200 rounded-lg p-3">
        <div class="text-xs text-slate-500 mb-2">Instance Pool</div>
        <div class="flex items-center gap-1 mb-2">
          <span class="inline-block w-3 h-3 bg-green-500 rounded-sm"></span>
          <span class="text-[10px] text-slate-500 mr-2">active</span>
          <span class="inline-block w-3 h-3 bg-blue-300 rounded-sm"></span>
          <span class="text-[10px] text-slate-500 mr-2">idle</span>
          <span class="inline-block w-3 h-3 bg-slate-200 rounded-sm"></span>
          <span class="text-[10px] text-slate-500">empty</span>
        </div>
        <div class="flex flex-wrap gap-1">
          <span
            v-for="(state, idx) in instanceSlots"
            :key="idx"
            class="w-4 h-4 rounded-sm"
            :class="{
              'bg-green-500': state === 'active',
              'bg-blue-300': state === 'idle',
              'bg-slate-200': state === 'empty',
            }"
          ></span>
        </div>
      </div>
    </template>
  </div>
</template>
