<script setup>
import { ref, computed, onMounted } from 'vue'
import { fetchWbSchedules, createWbSchedule, updateWbSchedule, deleteWbSchedule, toggleWbSchedule, fetchServices, fetchApps } from '../api'
import {
  Calendar, Plus, Trash2, RefreshCw, Pencil, Power, AlertTriangle,
  ChevronDown, ChevronRight, Play, Clock, CheckCircle, XCircle, Pause
} from 'lucide-vue-next'
import Modal from './Modal.vue'

const schedules = ref([])
const services = ref([])
const apps = ref([])
const loading = ref(false)
const error = ref(null)

const activeTab = ref('list')

const showDialog = ref(false)
const editing = ref(null)
const form = ref({ name: '', app: '', service: '', task_type: 'backup', cron_expr: '', enabled: true, backup_path: '', target_path: '', description: '', manifest: '' })
const formError = ref(null)
const saving = ref(false)

const deleteTarget = ref(null)

const historyTarget = ref(null)

const showBulk = ref(false)
const bulkServices = ref([])
const bulkTemplate = ref('production')

const expanded = ref(new Set())

const cronPresets = [
  { label: 'Every 1 min', expr: '*/1 * * * *' },
  { label: 'Every 5 min', expr: '*/5 * * * *' },
  { label: 'Hourly', expr: '0 * * * *' },
  { label: 'Daily 2am', expr: '0 2 * * *' },
  { label: 'Daily 4am', expr: '0 4 * * *' },
  { label: 'Weekly Sun 3am', expr: '0 3 * * 0' },
]

const taskTypes = [
  { value: 'backup', label: 'Backup (data only)', color: 'bg-blue-100 text-blue-700' },
  { value: 'snapshot', label: 'Snapshot (data + WASM + config)', color: 'bg-indigo-100 text-indigo-700' },
  { value: 'gc', label: 'GC', color: 'bg-amber-100 text-amber-700' },
  { value: 'truncate', label: 'WAL Truncate', color: 'bg-violet-100 text-violet-700' },
  { value: 'export', label: 'Export', color: 'bg-green-100 text-green-700' },
  { value: 'import', label: 'Import', color: 'bg-cyan-100 text-cyan-700' },
]

const templates = {
  production: {
    label: 'Production Standard',
    tasks: [
      { task_type: 'backup', cron_expr: '0 2 * * *', name_suffix: '-daily-backup', description: 'Daily backup at 2am' },
      { task_type: 'gc', cron_expr: '0 3 * * 0', name_suffix: '-weekly-gc', description: 'Weekly GC Sunday 3am' },
    ]
  },
  minimal: {
    label: 'Minimal',
    tasks: [
      { task_type: 'backup', cron_expr: '0 2 * * 6', name_suffix: '-weekly-backup', description: 'Weekly backup Saturday 2am' },
    ]
  },
}

const groupedByService = computed(() => {
  const groups = {}
  for (const svc of services.value) {
    groups[svc.name] = { service: svc, tasks: [] }
  }
  for (const sched of schedules.value) {
    const key = sched.service || 'unassigned'
    if (!groups[key]) groups[key] = { service: { name: key }, tasks: [] }
    groups[key].tasks.push(sched)
  }
  return groups
})

const groupedByApp = computed(() => {
  const byService = groupedByService.value
  const out = []
  for (const app of apps.value) {
    const svcGroups = []
    for (const s of (app.services || [])) {
      const g = byService[s.name]
      if (g) svcGroups.push([s.name, g])
    }
    const appTasks = schedules.value.filter(s => s.app === app.name)
    if (svcGroups.length > 0 || appTasks.length > 0) {
      out.push({ app: app.name, kind: app.kind, services: svcGroups, appTasks })
    }
  }
  return out
})

const grouped = computed(() => Object.entries(groupedByService.value))

async function loadSchedules() {
  loading.value = true
  error.value = null
  try {
    const resp = await fetchWbSchedules()
    schedules.value = Array.isArray(resp) ? resp : (resp?.schedules ?? [])
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

async function loadServices() {
  try {
    const [svcs, appList] = await Promise.all([fetchServices(), fetchApps()])
    services.value = svcs
    apps.value = appList
    for (const svc of services.value) {
      const hasTasks = schedules.value.some(s => s.service === svc.name)
      if (hasTasks) expanded.value.add(svc.name)
    }
  } catch {
    services.value = []
    apps.value = []
  }
}

function toggleGroup(name) {
  if (expanded.value.has(name)) expanded.value.delete(name)
  else expanded.value.add(name)
}

function openCreate(appName) {
  editing.value = null
  const initialApp = appName || apps.value[0]?.name || ''
  form.value = {
    name: '',
    app: initialApp,
    service: '',
    task_type: 'backup',
    cron_expr: '',
    enabled: true,
    backup_path: '',
    target_path: '',
    description: '',
    manifest: '',
  }
  formError.value = null
  showDialog.value = true
}

const servicesForSelectedApp = computed(() => {
  const a = apps.value.find(x => x.name === form.value.app)
  return a?.services || []
})

function openEdit(sched) {
  editing.value = sched
  const out = { ...sched }
  if (sched.task_type === 'backup') {
    out.service = ''
    if (!out.app) out.app = ''
  } else {
    if (!out.app) {
      const svc = services.value.find(s => s.name === sched.service)
      out.app = svc?.app || ''
    }
  }
  form.value = out
  formError.value = null
  showDialog.value = true
}

async function onSave() {
  formError.value = null
  if (!form.value.name.trim()) { formError.value = 'Name is required'; return }
  if (!form.value.cron_expr.trim()) { formError.value = 'Cron expression is required'; return }

  const isBackup = form.value.task_type === 'backup'
  if (isBackup) {
    if (!form.value.app?.trim()) { formError.value = 'App is required for backup tasks'; return }
  } else {
    if (!form.value.service?.trim()) { formError.value = 'Service is required for this task type'; return }
  }

  saving.value = true
  try {
    const params = {
      name: form.value.name,
      app: isBackup ? form.value.app : '',
      service: isBackup ? '' : form.value.service,
      task_type: form.value.task_type,
      cron_expr: form.value.cron_expr,
      enabled: String(form.value.enabled),
      backup_path: form.value.backup_path || '',
      target_path: form.value.target_path || '',
      description: form.value.description || '',
      manifest: form.value.manifest || '',
    }
    if (editing.value) await updateWbSchedule(params)
    else await createWbSchedule(params)
    showDialog.value = false
    await loadSchedules()
  } catch (e) {
    formError.value = e.message
  } finally {
    saving.value = false
  }
}

async function onToggle(sched) {
  try {
    await toggleWbSchedule(sched.name)
    await loadSchedules()
  } catch (e) {
    error.value = e.message
  }
}

async function onDelete(sched) {
  try {
    await deleteWbSchedule(sched.name)
    deleteTarget.value = null
    await loadSchedules()
  } catch (e) {
    error.value = e.message
  }
}

async function applyTemplate() {
  if (bulkServices.value.length === 0) { error.value = 'Select at least one service'; return }
  const tpl = templates[bulkTemplate.value]
  if (!tpl) return

  saving.value = true
  error.value = null
  let staggerMinutes = 0
  try {
    for (const svcName of bulkServices.value) {
      for (const task of tpl.tasks) {
        let expr = task.cron_expr
        if ((task.task_type === 'backup' || task.task_type === 'snapshot') && staggerMinutes > 0) {
          const parts = expr.split(' ')
          const baseMin = parseInt(parts[0]) || 0
          parts[0] = String((baseMin + staggerMinutes) % 60)
          if (baseMin + staggerMinutes >= 60) {
            const baseHour = parseInt(parts[1]) || 0
            parts[1] = String(baseHour + Math.floor((baseMin + staggerMinutes) / 60))
          }
          expr = parts.join(' ')
        }
        await createWbSchedule({
          name: svcName + task.name_suffix,
          service: svcName,
          task_type: task.task_type,
          cron_expr: expr,
          enabled: 'true',
          description: task.description,
        }).catch(() => { })
      }
      staggerMinutes += 15
    }
    showBulk.value = false
    await loadSchedules()
  } catch (e) {
    error.value = e.message
  } finally {
    saving.value = false
  }
}

function formatDate(ts) {
  if (!ts) return '-'
  return new Date(ts).toLocaleString()
}

function taskTypeStyle(type) {
  return taskTypes.find(t => t.value === type)?.color || 'bg-slate-100 text-slate-600'
}

function statusIcon(sched) {
  if (!sched.enabled) return { icon: Pause, class: 'text-slate-400' }
  if (sched.last_status === 'failed') return { icon: XCircle, class: 'text-red-500' }
  if (sched.last_status === 'ok') return { icon: CheckCircle, class: 'text-green-500' }
  return { icon: Clock, class: 'text-slate-400' }
}

const timelineHours = Array.from({ length: 24 }, (_, i) => i)

function taskTimelineSlots(sched) {
  if (!sched.cron_expr) return []
  const parts = sched.cron_expr.split(' ')
  if (parts.length < 5) return []
  const minute = parts[0]
  const hour = parts[1]

  if (hour === '*' || hour.startsWith('*/')) {
    const interval = hour === '*' ? 1 : parseInt(hour.replace('*/', ''))
    const slots = []
    for (let h = 0; h < 24; h += interval) slots.push(h)
    return slots
  }
  if (hour.includes(',')) return hour.split(',').map(Number)
  const h = parseInt(hour)
  if (!isNaN(h)) return [h]
  return []
}

const taskColors = ['bg-blue-500', 'bg-green-500', 'bg-amber-500', 'bg-violet-500', 'bg-red-500', 'bg-cyan-500', 'bg-pink-500', 'bg-emerald-500']

function serviceColor(idx) {
  return taskColors[idx % taskColors.length]
}

function toggleBulkService(name) {
  const idx = bulkServices.value.indexOf(name)
  if (idx >= 0) bulkServices.value.splice(idx, 1)
  else bulkServices.value.push(name)
}

onMounted(async () => {
  await loadSchedules()
  await loadServices()
})
</script>

<template>
  <div class="flex-1 flex flex-col bg-white text-slate-800 min-w-0 overflow-hidden">
    <div class="flex items-center px-6 py-3 border-b border-slate-200 shrink-0">
      <Calendar :size="18" class="text-blue-600 mr-2" />
      <span class="text-sm font-semibold text-slate-800">Scheduler</span>

      <div class="ml-6 flex gap-0">
        <button class="px-3 py-1 text-xs font-medium border-b-2 transition-colors"
          :class="activeTab === 'list' ? 'border-blue-600 text-blue-700' : 'border-transparent text-slate-400 hover:text-slate-600'"
          @click="activeTab = 'list'">Task List</button>
        <button class="px-3 py-1 text-xs font-medium border-b-2 transition-colors"
          :class="activeTab === 'timeline' ? 'border-blue-600 text-blue-700' : 'border-transparent text-slate-400 hover:text-slate-600'"
          @click="activeTab = 'timeline'">Timeline</button>
      </div>

      <div class="ml-auto flex gap-2">
        <button
          class="px-2 py-1 text-xs text-slate-500 hover:text-slate-700 hover:bg-slate-100 rounded flex items-center gap-1"
          @click="showBulk = true">
          Bulk Apply
        </button>
        <button
          class="px-2 py-1 text-xs text-slate-500 hover:text-slate-700 hover:bg-slate-100 rounded flex items-center gap-1"
          :disabled="loading" @click="loadSchedules">
          <RefreshCw :size="12" :class="{ 'animate-spin': loading }" /> Refresh
        </button>
        <button class="px-2.5 py-1 text-xs bg-blue-600 text-white rounded hover:bg-blue-500 flex items-center gap-1"
          @click="openCreate()">
          <Plus :size="12" /> New Task
        </button>
      </div>
    </div>

    <div v-if="error" class="px-6 py-2 bg-red-50 border-b border-red-200 text-xs text-red-600 flex items-center gap-2">
      <AlertTriangle :size="14" />{{ error }}
      <button class="ml-auto text-red-400 hover:text-red-600" @click="error = null">&times;</button>
    </div>

    <div v-if="activeTab === 'list'" class="flex-1 overflow-auto px-6 py-4">
      <div v-if="grouped.length === 0 && !loading" class="flex items-center justify-center py-16">
        <div class="text-center">
          <Calendar :size="32" class="mx-auto text-slate-300 mb-2" />
          <p class="text-sm text-slate-500">No schedules</p>
          <p class="text-xs text-slate-400 mt-1">Create a schedule to automate backup, GC, or stats collection</p>
        </div>
      </div>

      <div v-else class="space-y-3">
        <div v-for="appGroup in groupedByApp" :key="'app:' + appGroup.app">
          <div class="flex items-center gap-2 px-2 py-1 border-b border-slate-200 mb-1">
            <span class="text-xs font-semibold text-slate-600 uppercase tracking-wide">{{ appGroup.app }}</span>
            <span class="text-[10px] text-slate-400">{{ appGroup.services.length }} {{ appGroup.services.length === 1 ? 'service' : 'services' }}</span>
            <button class="ml-auto text-xs text-slate-400 hover:text-blue-600 px-2 py-0.5 rounded hover:bg-slate-100"
              @click.stop="openCreate(appGroup.app)">+ Add task</button>
          </div>

          <div v-if="appGroup.appTasks.length > 0" class="ml-2 mb-2 space-y-0.5">
            <div v-for="sched in appGroup.appTasks" :key="sched.name"
              class="flex items-center gap-3 px-3 py-2 rounded hover:bg-slate-50 text-xs transition-colors">
              <component :is="statusIcon(sched).icon" :size="14" :class="statusIcon(sched).class" />
              <span class="px-1.5 py-0.5 rounded text-[10px] font-medium" :class="taskTypeStyle(sched.task_type)">
                {{ sched.task_type }}
              </span>
              <span class="font-medium text-slate-700 min-w-[120px]">{{ sched.name }}</span>
              <span class="font-mono text-slate-400 min-w-[100px]">{{ sched.cron_expr }}</span>
              <span class="text-slate-400 min-w-[140px]">Last: {{ formatDate(sched.last_run_at) }}</span>
              <span class="text-slate-400 min-w-[140px]">Next: {{ formatDate(sched.next_run_at) }}</span>
              <div class="ml-auto flex gap-1">
                <button class="p-1 rounded hover:bg-slate-100" title="Toggle" @click="onToggle(sched)">
                  <Power :size="12" :class="sched.enabled ? 'text-green-500' : 'text-slate-400'" />
                </button>
                <button class="p-1 rounded hover:bg-slate-100" title="Edit" @click="openEdit(sched)">
                  <Pencil :size="12" class="text-slate-400" />
                </button>
                <button class="p-1 rounded hover:bg-slate-100" title="History" @click="historyTarget = sched">
                  <Clock :size="12" class="text-slate-400" />
                </button>
                <button class="p-1 rounded hover:bg-red-50" title="Delete" @click="deleteTarget = sched">
                  <Trash2 :size="12" class="text-red-400" />
                </button>
              </div>
            </div>
          </div>

          <div v-for="([svcName, group], idx) in appGroup.services" :key="svcName" class="ml-2">
          <div class="flex items-center gap-2 px-3 py-2 rounded-lg cursor-pointer hover:bg-slate-50 transition-colors"
            @click="toggleGroup(svcName)">
            <component :is="expanded.has(svcName) ? ChevronDown : ChevronRight" :size="14" class="text-slate-400" />
            <span class="w-2 h-2 rounded-full" :class="serviceColor(idx)" />
            <span class="text-sm font-medium text-slate-700">{{ svcName }}</span>
            <span class="text-xs text-slate-400">({{ group.tasks.length }} tasks)</span>
          </div>

          <div v-if="expanded.has(svcName)" class="ml-6 space-y-0.5 mb-2">
            <div v-for="sched in group.tasks" :key="sched.name"
              class="flex items-center gap-3 px-3 py-2 rounded hover:bg-slate-50 text-xs transition-colors">
              <component :is="statusIcon(sched).icon" :size="14" :class="statusIcon(sched).class" />

              <span class="px-1.5 py-0.5 rounded text-[10px] font-medium" :class="taskTypeStyle(sched.task_type)">
                {{ sched.task_type }}
              </span>

              <span class="font-medium text-slate-700 min-w-[120px]">{{ sched.name }}</span>

              <span class="font-mono text-slate-400 min-w-[100px]">{{ sched.cron_expr }}</span>

              <span class="text-slate-400 min-w-[140px]">Last: {{ formatDate(sched.last_run_at) }}</span>

              <span class="text-slate-400 min-w-[140px]">Next: {{ formatDate(sched.next_run_at) }}</span>

              <div class="ml-auto flex gap-1">
                <button class="p-1 rounded hover:bg-slate-100 transition-colors" title="Toggle"
                  @click="onToggle(sched)">
                  <Power :size="12" :class="sched.enabled ? 'text-green-500' : 'text-slate-400'" />
                </button>
                <button class="p-1 rounded hover:bg-slate-100 transition-colors" title="Edit" @click="openEdit(sched)">
                  <Pencil :size="12" class="text-slate-400" />
                </button>
                <button class="p-1 rounded hover:bg-slate-100 transition-colors" title="History"
                  @click="historyTarget = sched">
                  <Clock :size="12" class="text-slate-400" />
                </button>
                <button class="p-1 rounded hover:bg-red-50 transition-colors" title="Delete"
                  @click="deleteTarget = sched">
                  <Trash2 :size="12" class="text-red-400" />
                </button>
              </div>
            </div>

            <div v-if="group.tasks.length === 0" class="px-3 py-2 text-xs text-slate-400">
              No tasks scheduled
            </div>
          </div>
          </div>
        </div>
      </div>
    </div>

    <div v-if="activeTab === 'timeline'" class="flex-1 overflow-auto px-6 py-4">
      <div class="text-xs text-slate-400 mb-3">24-hour view showing scheduled task times</div>

      <div class="flex items-center mb-1 ml-32">
        <div v-for="h in timelineHours" :key="h"
          class="flex-1 text-center text-[10px] text-slate-400 border-l border-slate-200">
          {{ String(h).padStart(2, '0') }}
        </div>
      </div>

      <template v-for="appGroup in groupedByApp" :key="'tl:' + appGroup.app">
        <div class="flex items-center mt-3 mb-1 ml-32">
          <span class="text-xs font-semibold text-slate-600 uppercase tracking-wide">{{ appGroup.app }}</span>
        </div>
        <div v-for="([svcName, group], idx) in appGroup.services" :key="svcName" class="flex items-center mb-0.5">
          <div class="w-32 shrink-0 text-xs text-slate-500 truncate pr-2 flex items-center gap-1.5 pl-2">
            <span class="w-2 h-2 rounded-full shrink-0" :class="serviceColor(idx)" />
            {{ svcName }}
          </div>
          <div class="flex-1 flex h-6 bg-slate-100 rounded relative">
            <div v-for="h in timelineHours" :key="h" class="flex-1 border-l border-slate-200/50" />

            <template v-for="sched in group.tasks" :key="sched.name">
              <div v-for="hour in taskTimelineSlots(sched)" :key="`${sched.name}-${hour}`"
                class="absolute top-0.5 bottom-0.5 rounded text-[9px] font-medium flex items-center justify-center text-white/80 cursor-pointer hover:opacity-80"
                :class="serviceColor(idx)" :style="{ left: `${(hour / 24) * 100}%`, width: `${(1 / 24) * 100}%` }"
                :title="`${sched.name} (${sched.task_type}) at ${String(hour).padStart(2, '0')}:00`">
                {{ sched.task_type.substring(0, 3).toUpperCase() }}
              </div>
            </template>
          </div>
        </div>
      </template>

      <div v-if="grouped.length === 0" class="py-16 text-center text-slate-400 text-sm">
        No schedules to display
      </div>
    </div>

    <Modal v-if="showDialog" :title="editing ? 'Edit Schedule' : 'New Schedule'" @close="showDialog = false">
      <div class="space-y-3">
        <div v-if="formError" class="p-2 bg-red-50 border border-red-200 rounded text-xs text-red-600">{{ formError }}
        </div>
        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">Name</label>
          <input v-model="form.name" :disabled="!!editing" type="text"
            class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500"
            placeholder="inventory-weekly-backup" />
        </div>
        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">App</label>
          <select v-model="form.app"
            class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500">
            <option v-for="a in apps" :key="a.name" :value="a.name">{{ a.name }}</option>
          </select>
        </div>
        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">Task Type</label>
          <select v-model="form.task_type"
            class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500">
            <option v-for="t in taskTypes" :key="t.value" :value="t.value">{{ t.label }}</option>
          </select>
          <p v-if="form.task_type === 'backup'" class="text-[10px] text-slate-400 mt-1">
            Backups are app-scoped — every service in the app is quiesced as a unit.
          </p>
        </div>
        <div v-if="form.task_type !== 'backup'">
          <label class="block text-xs font-medium text-slate-600 mb-1">Service</label>
          <select v-model="form.service"
            class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500">
            <option value="" disabled>Select a service…</option>
            <option v-for="svc in servicesForSelectedApp" :key="svc.name" :value="svc.name">{{ svc.name }}</option>
          </select>
        </div>
        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">Cron Expression</label>
          <input v-model="form.cron_expr" type="text"
            class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500 font-mono"
            placeholder="0 2 * * 6" />
          <div class="flex gap-1.5 mt-1">
            <button v-for="p in cronPresets" :key="p.expr"
              class="px-1.5 py-0.5 text-[10px] bg-slate-100 hover:bg-slate-200 rounded text-slate-500"
              @click="form.cron_expr = p.expr">{{ p.label }}</button>
          </div>
        </div>
        <div v-if="form.task_type === 'backup'">
          <label class="block text-xs font-medium text-slate-600 mb-1">Backup Path</label>
          <input v-model="form.backup_path" type="text"
            class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500 font-mono"
            placeholder="/backups/inventory" />
        </div>
        <div v-if="form.task_type === 'snapshot'">
          <label class="block text-xs font-medium text-slate-600 mb-1">Snapshot Root (optional)</label>
          <input v-model="form.backup_path" type="text"
            class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500 font-mono"
            placeholder="Leave blank to use service's backup_dir" />
          <p class="text-[10px] text-amber-700 mt-1 bg-amber-50 border border-amber-200 rounded px-2 py-1">
            Snapshots include the WASM binary + config on top of the DB data - ~3× the size of a plain backup.
            The workbench has no automatic rotation yet, so a long-running schedule will eventually fill the volume.
            Set up out-of-band pruning (<code class="font-mono">cron find -mtime +N -delete</code>) until retention ships.
          </p>
        </div>
        <div v-if="form.task_type === 'export' || form.task_type === 'import'">
          <label class="block text-xs font-medium text-slate-600 mb-1">Manifest (YAML)</label>
          <textarea v-model="form.manifest" rows="6"
            class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500 font-mono resize-y"
            placeholder="store: my_store&#10;format: json&#10;output_dir: /tmp/export" />
        </div>
        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">Description</label>
          <input v-model="form.description" type="text"
            class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500"
            placeholder="Optional description" />
        </div>
        <label class="flex items-center gap-2 text-xs text-slate-600">
          <input type="checkbox" v-model="form.enabled" class="rounded" />
          Enabled
        </label>
      </div>
      <template #footer>
        <button class="px-3 py-1.5 text-xs text-slate-600 hover:bg-slate-100 rounded"
          @click="showDialog = false">Cancel</button>
        <button class="px-3 py-1.5 text-xs bg-blue-600 text-white rounded hover:bg-blue-700 disabled:opacity-50"
          :disabled="saving" @click="onSave">
          {{ saving ? 'Saving...' : (editing ? 'Update' : 'Create') }}
        </button>
      </template>
    </Modal>

    <div v-if="deleteTarget" class="fixed inset-0 bg-black/30 flex items-center justify-center z-50"
      @click.self="deleteTarget = null">
      <div class="bg-white border border-slate-200 rounded-lg p-5 w-80 shadow-xl">
        <div class="flex items-center gap-2 text-red-500 mb-3">
          <Trash2 :size="18" />
          <span class="text-sm font-medium">Delete Schedule</span>
        </div>
        <p class="text-xs text-slate-500 mb-3">Delete <strong class="text-slate-800">{{ deleteTarget.name }}</strong>?
        </p>
        <div class="flex justify-end gap-2">
          <button class="px-3 py-1.5 text-xs text-slate-500 hover:bg-slate-100 rounded"
            @click="deleteTarget = null">Cancel</button>
          <button class="px-3 py-1.5 text-xs bg-red-600 text-white rounded hover:bg-red-500"
            @click="onDelete(deleteTarget)">Delete</button>
        </div>
      </div>
    </div>

    <div v-if="historyTarget" class="fixed inset-0 bg-black/30 flex justify-end z-50"
      @click.self="historyTarget = null">
      <div class="w-96 bg-white border-l border-slate-200 shadow-xl flex flex-col">
        <div class="flex items-center justify-between px-4 py-3 border-b border-slate-200">
          <div>
            <h3 class="text-sm font-medium text-slate-800">Run History</h3>
            <p class="text-xs text-slate-400">{{ historyTarget.name }}</p>
          </div>
          <button class="text-slate-400 hover:text-slate-600 text-lg" @click="historyTarget = null">&times;</button>
        </div>
        <div class="flex-1 overflow-auto p-4">
          <div v-if="historyTarget.run_history?.length > 0" class="space-y-2">
            <div v-for="(run, i) in historyTarget.run_history" :key="i"
              class="p-2 bg-slate-50 rounded border border-slate-200 text-xs">
              <div class="flex items-center gap-2 mb-1">
                <component :is="run.status === 'ok' ? CheckCircle : XCircle" :size="12"
                  :class="run.status === 'ok' ? 'text-green-500' : 'text-red-500'" />
                <span class="text-slate-600">{{ formatDate(run.started_at) }}</span>
                <span v-if="run.duration_ms" class="text-slate-400 ml-auto">{{ run.duration_ms }}ms</span>
              </div>
              <p v-if="run.error" class="text-red-500 mt-1">{{ run.error }}</p>
            </div>
          </div>
          <div v-else class="py-8 text-center text-slate-400 text-xs">
            <Clock :size="24" class="mx-auto mb-2 text-slate-300" />
            No run history available yet
          </div>
        </div>
      </div>
    </div>

    <div v-if="showBulk" class="fixed inset-0 bg-black/30 flex items-center justify-center z-50"
      @click.self="showBulk = false">
      <div class="bg-white border border-slate-200 rounded-lg shadow-xl w-[28rem] max-h-[80vh] flex flex-col">
        <div class="flex items-center justify-between px-4 py-3 border-b border-slate-200">
          <h3 class="text-sm font-medium text-slate-800">Bulk Apply Template</h3>
          <button class="text-slate-400 hover:text-slate-600 text-lg" @click="showBulk = false">&times;</button>
        </div>
        <div class="p-4 overflow-auto space-y-4">
          <div>
            <label class="block text-xs text-slate-500 mb-1">Template</label>
            <select v-model="bulkTemplate"
              class="w-full bg-white border border-slate-300 rounded text-xs text-slate-800 px-3 py-2 focus:outline-none focus:border-blue-500">
              <option v-for="(tpl, key) in templates" :key="key" :value="key">{{ tpl.label }}</option>
            </select>
            <div class="mt-1.5 space-y-1">
              <div v-for="task in templates[bulkTemplate]?.tasks" :key="task.name_suffix"
                class="text-[10px] text-slate-400 flex gap-2">
                <span class="px-1 rounded" :class="taskTypeStyle(task.task_type)">{{ task.task_type }}</span>
                <span class="font-mono">{{ task.cron_expr }}</span>
                <span>{{ task.description }}</span>
              </div>
            </div>
          </div>

          <div>
            <label class="block text-xs text-slate-500 mb-1">Apply to services (backups staggered by 15 min)</label>
            <div class="max-h-48 overflow-auto border border-slate-200 rounded p-2 space-y-1">
              <label v-for="svc in services" :key="svc.name"
                class="flex items-center gap-2 text-xs text-slate-600 cursor-pointer hover:text-slate-800 py-0.5">
                <input type="checkbox" :checked="bulkServices.includes(svc.name)" @change="toggleBulkService(svc.name)"
                  class="rounded" />
                {{ svc.name }}
              </label>
            </div>
            <div class="flex gap-2 mt-1">
              <button class="text-[10px] text-blue-600 hover:text-blue-500"
                @click="bulkServices = services.map(s => s.name)">Select All</button>
              <button class="text-[10px] text-slate-400 hover:text-slate-500" @click="bulkServices = []">Deselect
                All</button>
            </div>
          </div>
        </div>
        <div class="flex justify-end gap-2 px-4 py-3 border-t border-slate-200">
          <button class="px-3 py-1.5 text-xs text-slate-500 hover:bg-slate-100 rounded"
            @click="showBulk = false">Cancel</button>
          <button class="px-3 py-1.5 text-xs bg-blue-600 text-white rounded hover:bg-blue-500 disabled:opacity-50"
            :disabled="saving || bulkServices.length === 0" @click="applyTemplate">
            {{ saving ? 'Applying...' : `Apply to ${bulkServices.length} service${bulkServices.length !== 1 ? 's' : ''}` }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
