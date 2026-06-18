<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { Play, Square, Trash2, Search, Plus, Server, Eye, EyeOff, Copy, Settings, RotateCw, Globe, Database, Zap } from 'lucide-vue-next'
import { fetchServices, fetchMonitorData, shellAppAction } from '../api'

const props = defineProps({
  services: { type: Array, default: () => [] },
  databases: { type: Array, default: () => [] },
  apps: { type: Array, default: () => [] },
  role: { type: String, default: 'standalone' },
  isAdmin: { type: Boolean, default: false },
  busyServices: { type: Object, default: () => ({}) },
})

const expandedApps = ref(new Set())

const emit = defineEmits(['navigate', 'service-action', 'deploy', 'refresh', 'open-overview'])

const filter = ref('')
const sortCol = ref('name')
const sortAsc = ref(true)
const stats = ref({})
const deleteTarget = ref(null)
const deleteConfirmName = ref('')
const visibleKeys = ref(new Set())
const copiedKey = ref(null)
let refreshTimer = null

function getServiceRole(serviceName) {
  const db = props.databases.find(d => d.name === serviceName)
  return db?.role || ''
}

function isServiceAdmin(serviceName) {
  return props.isAdmin || getServiceRole(serviceName) === 'admin'
}

const prevCpuTime = {}

async function loadStats() {
  const now = Date.now()
  for (const svc of props.services) {
    if (svc.status !== 'running') continue
    try {
      const data = await fetchMonitorData(svc.name)
      if (data) {
        const c = data.current
        let cpuPct = null
        if (data.cpu_time_us != null && prevCpuTime[svc.name]) {
          const dtMs = now - prevCpuTime[svc.name].ts
          const dCpu = data.cpu_time_us - prevCpuTime[svc.name].val
          if (dtMs > 0 && dCpu >= 0) {
            cpuPct = (dCpu / (dtMs * 1000)) * 100
          }
        }
        if (data.cpu_time_us != null) {
          prevCpuTime[svc.name] = { ts: now, val: data.cpu_time_us }
        }
        stats.value = {
          ...stats.value,
          [svc.name]: {
            cpu: cpuPct,
            mem: data.rss_mb ?? null,
            reads: c?.db?.total_reads ?? null,
            writes: c?.db?.total_writes ?? null,
            latency: c?.db?.avg_read_latency_us != null ? c.db.avg_read_latency_us / 1000 : null,
            docs: c?.index?.total_inserts ?? null,
          }
        }
      }
    } catch {  }
  }
}

onMounted(() => {
  loadStats()
  refreshTimer = setInterval(() => {
    emit('refresh')
    loadStats()
  }, 8000)
})

onUnmounted(() => {
  if (refreshTimer) clearInterval(refreshTimer)
})

const filtered = computed(() => {
  let list = props.services
  if (filter.value) {
    const q = filter.value.toLowerCase()
    list = list.filter(s => s.name.toLowerCase().includes(q) || (s.status || '').toLowerCase().includes(q))
  }
  return [...list].sort((a, b) => {
    let va = getSortValue(a, sortCol.value)
    let vb = getSortValue(b, sortCol.value)
    if (va == null && vb == null) return 0
    if (va == null) return 1
    if (vb == null) return -1
    if (typeof va === 'string') {
      const cmp = va.localeCompare(vb)
      return sortAsc.value ? cmp : -cmp
    }
    return sortAsc.value ? va - vb : vb - va
  })
})

const appHierarchy = computed(() => {
  const q = filter.value?.toLowerCase() || ''
  const isAdmin = props.role === 'admin'
  const result = []

  for (const app of props.apps) {
    if (app.kind === 'system' && !isAdmin) continue
    let svcs = (app.services || []).map(s => {
      const live = props.services.find(ls => ls.name === s.name)
      return live ? { ...s, ...live } : s
    })
    if (q) {
      svcs = svcs.filter(s => s.name.toLowerCase().includes(q) || app.name.toLowerCase().includes(q))
    }
    if (svcs.length > 0 || (!q && app.services?.length === 0)) {
      const running = svcs.filter(s => s.status === 'running').length
      result.push({
        type: 'app',
        name: app.name,
        description: app.description,
        kind: app.kind,
        services: svcs,
        running,
        total: svcs.length,
        shell_status: app.shell_status,
        shell_port: app.shell_port,
        shell_pid: app.shell_pid,
      })
    }
  }

  return result
})

function toggleApp(appName) {
  const s = new Set(expandedApps.value)
  if (s.has(appName)) s.delete(appName)
  else s.add(appName)
  expandedApps.value = s
}

function getSortValue(svc, col) {
  if (col === 'name') return svc.name
  if (col === 'status') return statusOrder(svc.status)
  const s = stats.value[svc.name]
  if (!s) return null
  if (col === 'cpu') return s.cpu
  if (col === 'mem') return s.mem
  if (col === 'reads') return s.reads
  if (col === 'writes') return s.writes
  if (col === 'latency') return s.latency
  if (col === 'docs') return s.docs
  return null
}

function statusOrder(s) {
  if (s === 'running') return 0
  if (s === 'degraded') return 1
  if (s === 'crashed') return 2
  return 3
}

function toggleSort(col) {
  if (sortCol.value === col) sortAsc.value = !sortAsc.value
  else { sortCol.value = col; sortAsc.value = true }
}

function sortIndicator(col) {
  if (sortCol.value !== col) return ''
  return sortAsc.value ? ' \u25B2' : ' \u25BC'
}

function statusColor(status) {
  if (status === 'running') return 'bg-green-500'
  if (status === 'degraded') return 'bg-yellow-500'
  if (status === 'crashed') return 'bg-red-500'
  return 'bg-slate-400'
}

function statusLabel(status) {
  if (status === 'running') return 'Running'
  if (status === 'degraded') return 'Degraded'
  if (status === 'crashed') return 'Crashed'
  if (status === 'failed') return 'Failed'
  return 'Stopped'
}

function cpuClass(v) {
  if (v == null) return ''
  if (v > 95) return 'text-red-600 font-semibold'
  if (v > 80) return 'text-amber-600 font-semibold'
  return ''
}

function latencyClass(v) {
  if (v == null) return ''
  if (v > 50) return 'text-red-600 font-semibold'
  if (v > 10) return 'text-amber-600 font-semibold'
  return ''
}

function fmtNum(v) {
  if (v == null) return '\u2014'
  if (v >= 1_000_000) return (v / 1_000_000).toFixed(1) + 'M'
  if (v >= 1_000) return (v / 1_000).toFixed(1) + 'K'
  return String(Math.round(v))
}

function fmtMem(v) {
  if (v == null) return '\u2014'
  return Math.round(v) + 'MB'
}

function fmtLatency(v) {
  if (v == null) return '\u2014'
  return v.toFixed(1) + 'ms'
}

function fmtPct(v) {
  if (v == null) return '\u2014'
  return v.toFixed(0) + '%'
}

function getStats(name) {
  return stats.value[name] || {}
}

function openService(svc) {
  emit('navigate', { type: 'query', service: svc.name })
}

const shellBusy = ref(new Set())

async function doShellAction(appName, action) {
  shellBusy.value.add(appName)
  try {
    await shellAppAction(appName, action)
    emit('refresh')
  } catch (e) {
    console.error(`Shell ${action} failed:`, e)
  } finally {
    shellBusy.value.delete(appName)
  }
}

function serviceIcon(svc) {
  return svc?.kind === 'sse_hub' ? Zap : Database
}

function serviceIconClass(svc) {
  return svc?.kind === 'sse_hub' ? 'text-purple-500 shrink-0' : 'text-amber-500 shrink-0'
}

function serviceTypeLabel(svc) {
  return svc.service_type || ''
}

function replicaStatusColor(replica) {
  if (!replica) return ''
  if (replica.status === 'running') return 'bg-green-500'
  if (replica.status === 'unreachable') return 'bg-red-500'
  if (replica.status === 'not_deployed') return 'bg-slate-400'
  return 'bg-amber-500'
}

function replicaStatusLabel(replica) {
  if (!replica) return ''
  if (replica.status === 'running') return 'Replica OK'
  if (replica.status === 'unreachable') return 'Replica Unreachable'
  if (replica.status === 'not_deployed') return 'Replica Not Deployed'
  return 'Replica ' + replica.status
}

function confirmDelete(svc) {
  deleteTarget.value = svc
  deleteConfirmName.value = ''
}

function doDelete() {
  if (deleteTarget.value && deleteConfirmName.value === deleteTarget.value.name) {
    emit('service-action', { type: 'undeploy', name: deleteTarget.value.name })
    deleteTarget.value = null
  }
}

function toggleKeyVisibility(name) {
  if (visibleKeys.value.has(name)) visibleKeys.value.delete(name)
  else visibleKeys.value.add(name)
}

function copyKey(svc) {
  if (svc.admin_key) {
    navigator.clipboard.writeText(svc.admin_key)
    copiedKey.value = svc.name
    setTimeout(() => { copiedKey.value = null }, 1500)
  }
}

function maskedKey(key) {
  if (!key) return ''
  if (key.length <= 8) return key
  return key.substring(0, 4) + '...' + key.substring(key.length - 4)
}

const hasAnyAdmin = computed(() => {
  return props.isAdmin || props.services.some(s => isServiceAdmin(s.name))
})

const columns = [
  { key: 'name', label: 'Service', w: 'flex-1' },
  { key: 'status', label: 'Status', w: 'w-20' },
  { key: 'cpu', label: 'CPU', w: 'w-16 text-right' },
  { key: 'mem', label: 'Mem', w: 'w-20 text-right' },
  { key: 'reads', label: 'Reads', w: 'w-20 text-right' },
  { key: 'writes', label: 'Writes', w: 'w-20 text-right' },
  { key: 'latency', label: 'Latency', w: 'w-20 text-right' },
  { key: 'docs', label: 'Indexed', w: 'w-20 text-right' },
]
</script>

<template>
  <div class="flex-1 flex flex-col bg-white text-slate-800 overflow-hidden">
    <div class="flex items-center justify-between px-6 py-4 border-b border-slate-200">
      <h1 class="text-lg font-semibold text-slate-800">Services</h1>
      <div class="flex items-center gap-3">
        <div class="relative">
          <Search :size="14" class="absolute left-2.5 top-1/2 -translate-y-1/2 text-slate-400" />
          <input
            v-model="filter"
            type="text"
            placeholder="Filter services..."
            class="bg-white border border-slate-300 rounded text-xs text-slate-800 pl-8 pr-3 py-1.5 w-48 focus:outline-none focus:border-blue-500"
          />
        </div>


      </div>
    </div>

    <div class="flex-1 overflow-auto px-6 py-2">
      <table class="w-full text-xs">
        <thead>
          <tr class="text-slate-500 border-b border-slate-200">
            <th
              v-for="col in columns"
              :key="col.key"
              :class="[col.w, 'py-2 px-2 font-medium cursor-pointer hover:text-slate-800 select-none text-left']"
              @click="toggleSort(col.key)"
            >
              {{ col.label }}{{ sortIndicator(col.key) }}
            </th>
            <th class="w-20 py-2 px-2 font-medium text-right">Key</th>
            <th v-if="hasAnyAdmin" class="w-28 py-2 px-2 font-medium text-right">Actions</th>
          </tr>
        </thead>
        <tbody>
          <template v-for="item in appHierarchy" :key="item.type + ':' + item.name">

            <tr v-if="item.type === 'app'"
              class="border-b border-slate-200 bg-slate-50 hover:bg-slate-100 transition-colors"
            >
              <td class="py-2 px-2" :colspan="columns.length">
                <div class="flex items-center gap-2 cursor-pointer" @click="toggleApp(item.name)">
                  <span class="text-slate-400 text-[10px] w-4 text-center">{{ expandedApps.has(item.name) ? '▼' : '▶' }}</span>
                  <span class="font-semibold text-slate-700">{{ item.name }}</span>
                  <span class="text-slate-400 text-[10px]">{{ item.description }}</span>
                  <span v-if="item.shell_status && item.shell_status !== 'not_deployed'"
                    class="flex items-center gap-1 text-[10px] px-1.5 py-0.5 rounded font-medium"
                    :class="item.shell_status === 'running' ? 'bg-green-100 text-green-700' : item.shell_status === 'crashed' ? 'bg-red-100 text-red-700' : 'bg-slate-100 text-slate-600'"
                  >
                    <Globe :size="10" />
                    Shell: {{ item.shell_status }}
                    <span v-if="item.shell_port > 0" class="text-slate-400">:{{ item.shell_port }}</span>
                  </span>
                  <span class="text-[10px] px-1.5 py-0.5 rounded bg-slate-200 text-slate-600">{{ item.running }}/{{ item.total }} services</span>
                </div>
              </td>
              <td v-if="hasAnyAdmin" class="py-2 px-2 text-right">
                <div class="flex items-center justify-end gap-1" v-if="item.shell_status && item.shell_status !== 'not_deployed'">
                  <button
                    v-if="item.shell_status !== 'running'"
                    class="p-1 rounded text-green-600 hover:bg-green-50 transition-colors"
                    title="Start shell app"
                    :disabled="shellBusy.has(item.name)"
                    @click.stop="doShellAction(item.name, 'start')"
                  ><Play :size="13" /></button>
                  <button
                    v-if="item.shell_status === 'running'"
                    class="p-1 rounded text-red-500 hover:bg-red-50 transition-colors"
                    title="Stop shell app"
                    :disabled="shellBusy.has(item.name)"
                    @click.stop="doShellAction(item.name, 'stop')"
                  ><Square :size="13" /></button>
                  <button
                    class="p-1 rounded text-slate-500 hover:bg-slate-100 transition-colors"
                    title="Restart shell app"
                    :disabled="shellBusy.has(item.name)"
                    @click.stop="doShellAction(item.name, 'restart')"
                  ><RotateCw :size="13" /></button>
                </div>
              </td>
            </tr>

            <template v-if="item.type === 'app' && expandedApps.has(item.name)">
              <tr
                v-for="svc in item.services" :key="svc.name"
                class="border-b border-slate-100 hover:bg-slate-50 cursor-pointer transition-colors"
                @click="openService(svc)"
              >
                <td class="py-2 px-2 pl-8">
                  <div class="flex items-center gap-2">
                    <component :is="serviceIcon(svc)" :size="14" :class="serviceIconClass(svc)" />
                    <span class="font-medium text-slate-800">{{ svc.service_name || svc.name }}</span>
                    <span v-if="svc.port" class="text-slate-400 text-[10px]">:{{ svc.port }}</span>
                    <span v-if="svc.wasm_port" class="text-emerald-500 text-[10px]" title="WASM port">wasm:{{ svc.wasm_port }}</span>
                    <span
                      v-if="serviceTypeLabel(svc)"
                      class="text-[9px] px-1.5 py-0.5 rounded font-medium"
                      :class="serviceTypeLabel(svc) === 'command' ? 'bg-blue-100 text-blue-700' : serviceTypeLabel(svc) === 'query' ? 'bg-amber-100 text-amber-700' : 'bg-slate-100 text-slate-600'"
                    >{{ serviceTypeLabel(svc) }}</span>
                    <span
                      v-if="svc.replica"
                      class="flex items-center gap-1 text-[9px] px-1.5 py-0.5 rounded font-medium bg-slate-50 border border-slate-200"
                    >
                      <span class="w-1.5 h-1.5 rounded-full" :class="replicaStatusColor(svc.replica)" />
                      <span class="text-slate-500">replica</span>
                    </span>
                  </div>
                </td>
                <td class="py-2 px-2">
                  <span class="flex items-center gap-2">
                    <span class="w-2 h-2 rounded-full" :class="statusColor(svc.status)" />
                    <span class="text-slate-600 text-[11px]">{{ statusLabel(svc.status) }}</span>
                  </span>
                </td>
                <td class="py-2 px-2 text-right text-slate-600" :class="cpuClass(getStats(svc.name).cpu)">{{ fmtPct(getStats(svc.name).cpu) }}</td>
                <td class="py-2 px-2 text-right text-slate-600">{{ fmtMem(getStats(svc.name).mem) }}</td>
                <td class="py-2 px-2 text-right text-slate-600">{{ fmtNum(getStats(svc.name).reads) }}</td>
                <td class="py-2 px-2 text-right text-slate-600">{{ fmtNum(getStats(svc.name).writes) }}</td>
                <td class="py-2 px-2 text-right text-slate-600" :class="latencyClass(getStats(svc.name).latency)">{{ fmtLatency(getStats(svc.name).latency) }}</td>
                <td class="py-2 px-2 text-right text-slate-600">{{ fmtNum(getStats(svc.name).docs) }}</td>
                <td class="py-2 px-2 text-right" @click.stop>
                  <div v-if="svc.admin_key" class="flex items-center justify-end gap-1">
                    <span class="text-[10px] font-mono text-slate-400">{{ visibleKeys.has(svc.name) ? svc.admin_key : maskedKey(svc.admin_key) }}</span>
                    <button class="p-0.5 text-slate-400 hover:text-slate-600 rounded" @click="toggleKeyVisibility(svc.name)"><component :is="visibleKeys.has(svc.name) ? EyeOff : Eye" :size="11" /></button>
                    <button class="p-0.5 rounded" :class="copiedKey === svc.name ? 'text-green-600' : 'text-slate-400 hover:text-slate-600'" @click="copyKey(svc)"><Copy :size="11" /></button>
                  </div>
                </td>
                <td v-if="hasAnyAdmin" class="py-2 px-2 text-right" @click.stop>
                  <div v-if="isServiceAdmin(svc.name)" class="flex items-center justify-end gap-1">
                    <button v-if="svc.kind !== 'sse_hub'" class="p-1 rounded hover:bg-slate-100 text-slate-400 hover:text-blue-600 transition-colors" title="Manage" @click="emit('open-overview', svc.name)"><Settings :size="13" /></button>
                    <template v-if="busyServices[svc.name]">
                      <span class="p-1 text-xs text-amber-500 animate-pulse">{{ busyServices[svc.name] === 'stop' ? 'Stopping...' : busyServices[svc.name] === 'start' ? 'Starting...' : 'Working...' }}</span>
                    </template>
                    <template v-else>
                      <button v-if="svc.status === 'running'" class="p-1 rounded hover:bg-slate-100 text-slate-400 hover:text-amber-600 transition-colors" title="Stop" @click="emit('service-action', { type: 'stop', name: svc.name })"><Square :size="13" /></button>
                      <button v-else class="p-1 rounded hover:bg-slate-100 text-slate-400 hover:text-green-600 transition-colors" title="Start" @click="emit('service-action', { type: 'start', name: svc.name })"><Play :size="13" /></button>
                    </template>
                    <button class="p-1 rounded hover:bg-slate-100 text-slate-400 hover:text-red-500 transition-colors" title="Delete" @click="confirmDelete(svc)"><Trash2 :size="13" /></button>
                  </div>
                </td>
              </tr>
            </template>


          </template>

          <tr v-if="appHierarchy.length === 0">
            <td :colspan="columns.length + 2" class="py-8 text-center text-slate-400">
              {{ filter ? 'No services match the filter' : 'No services deployed' }}
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <div v-if="deleteTarget" class="fixed inset-0 bg-black/30 flex items-center justify-center z-50">
      <div class="bg-white border border-slate-200 rounded-lg p-6 w-96 shadow-xl">
        <h3 class="text-sm font-semibold text-slate-800 mb-3">Delete "{{ deleteTarget.name }}" service?</h3>
        <p class="text-xs text-slate-500 mb-4">This will stop and remove the service permanently. Type the service name to confirm.</p>
        <input
          v-model="deleteConfirmName"
          type="text"
          :placeholder="deleteTarget.name"
          class="w-full bg-white border border-slate-300 rounded text-xs text-slate-800 px-3 py-2 mb-4 focus:outline-none focus:border-red-500"
          @keyup.enter="doDelete"
        />
        <div class="flex justify-end gap-2">
          <button
            class="px-3 py-1.5 text-xs text-slate-500 hover:text-slate-700 rounded hover:bg-slate-100 transition-colors"
            @click="deleteTarget = null"
          >
            Cancel
          </button>
          <button
            class="px-3 py-1.5 text-xs font-medium rounded transition-colors"
            :class="deleteConfirmName === deleteTarget.name ? 'bg-red-600 hover:bg-red-500 text-white' : 'bg-slate-100 text-slate-400 cursor-not-allowed'"
            :disabled="deleteConfirmName !== deleteTarget.name"
            @click="doDelete"
          >
            Delete
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
