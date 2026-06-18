<script setup>
import { ref, watch, computed } from 'vue'
import {
  ChevronRight, ChevronDown, Table2, Key,
  Plus, Trash2, Download, Upload, RotateCcw, RefreshCw,
  Play, Square, ArrowLeft, Database
} from 'lucide-vue-next'
import { dropSchema, listUsers, createUser, deleteUser, updateUser, regenerateKey, getConfig, setConfig, setServerMode, demoteServer, promoteServer, fetchServices, fetchDatabases, updateWasm } from '../api'
import ConfirmDialog from './ConfirmDialog.vue'
import ConfirmDropDialog from './ConfirmDropDialog.vue'
import Modal from './Modal.vue'
import CreateStoreDialog from './CreateStoreDialog.vue'
import CreateIndexDialog from './CreateIndexDialog.vue'
import ExportDialog from './ExportDialog.vue'
import ImportDialog from './ImportDialog.vue'

const props = defineProps({
  stores: Array,
  serviceName: String,
  dbName: String,
  role: { type: String, default: '' },
  serviceStatus: { type: String, default: '' },
  initialTab: { type: String, default: 'schema' },
  showBack: { type: Boolean, default: false },
  connectedUid: { type: String, default: '' },
})

const isAdmin = computed(() => props.role === 'admin')
const canWrite = computed(() => props.role === 'admin' || props.role === 'read_write')

const emit = defineEmits(['schema-changed', 'service-action', 'close'])

const activeTab = ref(props.initialTab)

watch(() => props.initialTab, (v) => { activeTab.value = v })

const expandedStores = ref(new Set())
const confirmDialog = ref(null)
const confirmLoading = ref(false)
const createDialog = ref(null)

const users = ref([])
const usersLoading = ref(false)
const usersError = ref(null)
const showCreateUser = ref(false)
const newUser = ref({ username: '', role: '2' })
const createUserLoading = ref(false)
const createUserError = ref(null)
const generatedKey = ref(null)
const regeneratedKey = ref(null)
const regeneratedUser = ref('')

const configData = ref(null)
const configForm = ref(null)
const configLoading = ref(false)
const configError = ref(null)
const configSaving = ref(false)
const configSaved = ref(false)

const showExportDialog = ref(false)
const showImportDialog = ref(false)
const eximStore = ref('')

function openExim(type, store) {
  eximStore.value = store?.ns || ''
  if (type === 'export') showExportDialog.value = true
  else showImportDialog.value = true
}

const tabs = computed(() => {
  const t = [
    { key: 'schema', label: 'Schema' },
    { key: 'config', label: 'Configuration' },
    { key: 'users', label: 'Users' },
  ]
  if (isAdmin.value && props.serviceName === 'systemdb') t.push({ key: 'permissions', label: 'Permissions' })
  return t
})

const actionLoading = ref(false)
async function onServiceAction(type) {
  actionLoading.value = true
  try {
    emit('service-action', { type, name: props.dbName })
  } finally {
    actionLoading.value = false
  }
}

const wasmUpdating = ref(false)
async function onUpdateWasm() {
  const input = document.createElement('input')
  input.type = 'file'
  input.accept = '.wasm'
  input.onchange = async () => {
    const file = input.files?.[0]
    if (!file) return
    wasmUpdating.value = true
    try {
      await updateWasm(props.dbName, file)
      emit('service-action', { type: 'refresh', name: props.dbName })
    } catch (e) {
      alert(`WASM update failed: ${e.message}`)
    } finally {
      wasmUpdating.value = false
    }
  }
  input.click()
}

const wasmUploadStatus = ref(null)
async function onWasmUploadConfig(e) {
  const file = e.target.files?.[0]
  if (!file) return

  const baseName = props.serviceName.replace(/\.db\.(command|query|standalone)$/, '')
  const expected = `planck.${baseName}.wasm`
  if (file.name !== expected) {
    wasmUploadStatus.value = { ok: false, msg: `Expected ${expected}, got ${file.name}` }
    return
  }

  const header = new Uint8Array(await file.slice(0, 4).arrayBuffer())
  if (header[0] !== 0 || header[1] !== 0x61 || header[2] !== 0x73 || header[3] !== 0x6d) {
    wasmUploadStatus.value = { ok: false, msg: 'Invalid WASM binary (bad magic bytes)' }
    return
  }

  wasmUpdating.value = true
  wasmUploadStatus.value = null
  try {
    await updateWasm(props.serviceName, file)
    wasmUploadStatus.value = { ok: true, msg: `${file.name} uploaded - service restarting` }
    if (configForm.value?.wasm) configForm.value.wasm.enabled = true
    emit('service-action', { type: 'refresh', name: props.serviceName })
  } catch (err) {
    wasmUploadStatus.value = { ok: false, msg: err.message }
  } finally {
    wasmUpdating.value = false
  }
}

const serverOnline = ref(true)
const modeLoading = ref(false)

const isPrimary = ref(null)
const demotePromoteLoading = ref(false)

async function onDemotePromote() {
  const action = isPrimary.value ? 'demote' : 'promote'
  if (!confirm(`${action.charAt(0).toUpperCase() + action.slice(1)} this node?`)) return
  demotePromoteLoading.value = true
  try {
    if (isPrimary.value) {
      await demoteServer(props.serviceName)
      isPrimary.value = false
    } else {
      await promoteServer(props.serviceName)
      isPrimary.value = true
    }
  } catch (e) {
    alert(`Failed to ${action}: ` + e.message)
  } finally {
    demotePromoteLoading.value = false
  }
}

async function onToggleMode() {
  const newMode = serverOnline.value ? 'offline' : 'online'
  if (!confirm(`Set server to ${newMode.toUpperCase()} mode?`)) return
  modeLoading.value = true
  try {
    await setServerMode(props.serviceName, newMode)
    serverOnline.value = !serverOnline.value
  } catch (e) {
    alert('Failed to set mode: ' + e.message)
  } finally {
    modeLoading.value = false
  }
}

const configDirty = computed(() => JSON.stringify(configForm.value) !== JSON.stringify(configData.value))

watch(activeTab, (tab) => {
  if (tab === 'config' && !configData.value) loadConfig()
  if (tab === 'users' && users.value.length === 0) loadUsers()
  if (tab === 'permissions' && permUserList.value.length === 0) loadPermissions()
}, { immediate: true })

if (!configData.value) loadConfig()

const configSections = [
  { key: 'server', label: 'Server', fields: ['address', 'port', 'service_type', 'base_dir'], readonly: true },
  { key: 'tls', label: 'TLS', nested: 'tls', readonly: true },
  { key: 'session', label: 'Sessions', topFields: ['max_sessions'], nested: 'session' },
  { key: 'buffers', label: 'Buffers', nested: 'buffers', formatBytes: true },
  { key: 'durability', label: 'Durability', nested: 'durability' },
  { key: 'file_sizes', label: 'File Sizes', nested: 'file_sizes', formatBytes: true },
  { key: 'index', label: 'Index Pools', nested: 'index' },
  { key: 'cache', label: 'Cache', nested: 'cache' },
  { key: 'logging', label: 'Logging', nested: 'logging' },
  { key: 'gc', label: 'Garbage Collection', nested: 'gc' },
  { key: 'security', label: 'Security', nested: 'security' },
  { key: 'limits', label: 'Limits', nested: 'limits' },
  { key: 'replica', label: 'Replica', nested: 'replica' },
  { key: 'http', label: 'HTTP Server', nested: 'http' },
  { key: 'wasm', label: 'WASM', nested: 'wasm' },
]

function fieldLabel(key) {
  return key.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase())
}

function fieldType(val) {
  if (typeof val === 'boolean') return 'bool'
  if (typeof val === 'number') return 'number'
  if (val !== null && typeof val === 'object') return 'object'
  return 'text'
}

async function loadConfig() {
  configLoading.value = true
  configError.value = null
  try {
    const resp = await getConfig(props.serviceName)
    configData.value = resp.data ? (typeof resp.data === 'string' ? JSON.parse(resp.data) : resp.data) : {}
    configForm.value = JSON.parse(JSON.stringify(configData.value))
    if (configData.value.service_type !== undefined) isPrimary.value = (configData.value.service_type === 'command' || configData.value.service_type === 'standalone')
  } catch (e) {
    configError.value = e.message
  } finally {
    configLoading.value = false
  }
}

async function saveConfig() {
  configSaving.value = true
  configSaved.value = false
  configError.value = null
  try {
    await setConfig(props.serviceName, configForm.value)
    configData.value = JSON.parse(JSON.stringify(configForm.value))
    configSaved.value = true
    setTimeout(() => { configSaved.value = false }, 3000)
  } catch (e) {
    configError.value = e.message
  } finally {
    configSaving.value = false
  }
}

function resetConfig() {
  configForm.value = JSON.parse(JSON.stringify(configData.value))
}

function toggleStore(ns) {
  const s = new Set(expandedStores.value)
  if (s.has(ns)) s.delete(ns); else s.add(ns)
  expandedStores.value = s
}

function fieldTypeLabel(ft) { return ft || 'String' }

function onCreateStore() { createDialog.value = { type: 'create-store' } }
function onCreateIndex(storeNs) { createDialog.value = { type: 'create-index', storeNs } }

const dropDialog = ref(null)

function onDrop(type, ns) { dropDialog.value = { type, ns } }

function onDropped() {
  dropDialog.value = null
  emit('schema-changed')
}

function onDialogCreated() {
  createDialog.value = null
  emit('schema-changed')
}

async function loadUsers() {
  usersLoading.value = true
  usersError.value = null
  try {
    const resp = await listUsers(props.serviceName)
    users.value = parseUsersPayload(resp.data)
  } catch (e) {
    usersError.value = e.message
  } finally {
    usersLoading.value = false
  }
}

const ROLE_BY_ID = ['admin', 'read_write', 'read_only', 'none']

function normalizeRole(r) {
  if (typeof r === 'string') return r
  if (typeof r === 'number') return ROLE_BY_ID[r] ?? 'none'
  return 'none'
}

function parseListPayload(payload, key) {
  if (!payload) return []
  const parsed = typeof payload === 'string' ? JSON.parse(payload) : payload

  if (Array.isArray(parsed)) {
    if (parsed.length > 0 && parsed[0] && Array.isArray(parsed[0][key])) {
      return parsed[0][key]
    }
    return parsed
  }
  if (parsed && Array.isArray(parsed[key])) return parsed[key]
  return []
}

function parseUsersPayload(payload) {
  return parseListPayload(payload, 'users')
    .filter(u => u && u.username)
    .map(u => ({
      username: u.username,
      role: normalizeRole(u.role),
      created_at: u.created_at ?? 0,
    }))
}

function copyToClipboard(text) {
  navigator.clipboard.writeText(text)
}

async function onCreateUser() {
  createUserError.value = null
  generatedKey.value = null
  if (!newUser.value.username.trim()) { createUserError.value = 'Username is required'; return }

  createUserLoading.value = true
  try {
    const data = await createUser(props.serviceName, newUser.value.username, newUser.value.role)
    generatedKey.value = data.key

    newUser.value = { username: '', role: '2' }
    await loadUsers()
  } catch (e) {
    createUserError.value = e.message
  } finally {
    createUserLoading.value = false
  }
}

async function onDeleteUser(username) {
  confirmDialog.value = {
    action: 'delete-user',
    ns: username,
    label: username,
    handler: async () => {
      try {
        await deleteUser(props.serviceName, username)
        await loadUsers()
      } catch (e) {
        alert('Failed: ' + e.message)
      }
    }
  }
}

async function onRegenerateKey(username) {
  if (!confirm(`Regenerate key for "${username}"? The current key will stop working.`)) return
  try {
    const data = await regenerateKey(props.serviceName, username)
    regeneratedUser.value = username
    regeneratedKey.value = data.key
    await loadUsers()
  } catch (e) {
    alert('Failed: ' + e.message)
  }
}

const roleMap = { admin: '0', read_write: '1', read_only: '2', none: '3' }

async function onUpdateRole(username, newRole) {
  try {
    await updateUser(props.serviceName, username, roleMap[newRole])
    await loadUsers()
  } catch (e) {
    alert('Failed: ' + e.message)
  }
}

const permServices = ref([])
const permSelectedUser = ref('')
const permUserList = ref([])
const permRows = ref({})
const permLoading = ref(false)
const permError = ref(null)
const permSaving = ref({})
const permCopied = ref(null)

async function loadPermissions() {
  permLoading.value = true
  permError.value = null
  try {
    const userResp = await listUsers(props.serviceName)
    permUserList.value = parseUsersPayload(userResp.data).map(u => u.username)

    const [svcList, dbList] = await Promise.all([fetchServices(), fetchDatabases()])
    const connectedSet = new Set(dbList.filter(d => d.connected).map(d => d.name))
    const svcs = svcList.map(s => ({ name: s.name, connected: connectedSet.has(s.name) }))
    permServices.value = svcs

    if (permSelectedUser.value) {
      await loadUserPermissions(permSelectedUser.value, svcs)
    }
  } catch (e) {
    permError.value = e.message
  } finally {
    permLoading.value = false
  }
}

async function loadUserPermissions(username, svcs) {
  const services = svcs || permServices.value
  const rows = {}
  const results = await Promise.allSettled(
    services.filter(s => s.connected).map(async (s) => {
      const resp = await listUsers(s.name)
      const list = parseUsersPayload(resp.data)
      const user = list.find(u => u.username === username)
      return { name: s.name, role: user?.role || null, key: null }
    })
  )
  for (const r of results) {
    if (r.status === 'fulfilled') {
      rows[r.value.name] = { role: r.value.role, key: r.value.key }
    }
  }
  permRows.value = rows
}

async function onPermUserChange(username) {
  permSelectedUser.value = username
  permRows.value = {}
  if (!username) return
  permLoading.value = true
  try {
    await loadUserPermissions(username)
  } finally {
    permLoading.value = false
  }
}

async function permSetRole(service, newRole) {
  const username = permSelectedUser.value
  if (!username) return
  permSaving.value = { ...permSaving.value, [service]: true }
  try {
    const current = permRows.value[service]
    if (!current?.role || current.role === null) {
      const data = await createUser(service, username, roleMap[newRole])
      permRows.value = { ...permRows.value, [service]: { role: newRole, key: data.key } }
    } else {
      await updateUser(service, username, roleMap[newRole])
      permRows.value = { ...permRows.value, [service]: { ...current, role: newRole } }
    }
  } catch (e) {
    alert(`Failed to set role for ${username} on ${service}: ${e.message}`)
  } finally {
    const { [service]: _, ...rest } = permSaving.value
    permSaving.value = rest
  }
}

function permCopyKey(service) {
  const key = permRows.value[service]?.key
  if (key) {
    navigator.clipboard.writeText(key)
    permCopied.value = service
    setTimeout(() => { if (permCopied.value === service) permCopied.value = null }, 2000)
  }
}

async function handleConfirm() {
  if (!confirmDialog.value?.handler) return
  confirmLoading.value = true
  try {
    await confirmDialog.value.handler()
    confirmDialog.value = null
  } finally {
    confirmLoading.value = false
  }
}

function formatSize(bytes) {
  if (!bytes) return '—'
  if (bytes < 1024) return bytes + ' B'
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB'
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB'
  return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB'
}

function formatDate(ts) {
  if (!ts) return '—'
  return new Date(ts).toLocaleString()
}
</script>

<template>
  <div class="flex-1 flex flex-col overflow-hidden bg-white">
    <div class="bg-slate-100 border-b border-slate-200 px-4 py-2 flex items-center gap-3">
      <button
        v-if="showBack"
        class="p-1.5 rounded hover:bg-slate-200 text-slate-500 hover:text-slate-700 transition-colors"
        title="Back"
        @click="emit('close')"
      >
        <ArrowLeft :size="16" />
      </button>
      <Database :size="16" class="text-blue-500" />
      <span class="text-sm font-semibold text-slate-700">{{ dbName }}</span>
      <span
        v-if="connectedUid"
        class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-green-100 text-green-700"
      >
        <span class="w-1.5 h-1.5 rounded-full bg-green-500" />
        {{ connectedUid }} ({{ role }})
      </span>
      <span v-else class="text-[10px] text-slate-400">Not connected</span>

      <div class="ml-auto flex items-center gap-2">
        <template v-if="isAdmin">
          <template v-if="serviceStatus === 'running'">
            <button
              class="px-2 py-1 text-[11px] text-slate-600 hover:bg-slate-200 rounded flex items-center gap-1"
              :disabled="actionLoading"
              @click="onServiceAction('stop')"
            >
              <Square :size="11" /> Stop
            </button>
            <button
              class="px-2 py-1 text-[11px] text-slate-600 hover:bg-slate-200 rounded flex items-center gap-1"
              :disabled="actionLoading"
              @click="onServiceAction('restart')"
            >
              <RotateCcw :size="11" /> Restart
            </button>
            <button
              class="px-2 py-1 text-[11px] text-blue-600 hover:bg-blue-50 rounded flex items-center gap-1"
              :disabled="wasmUpdating"
              @click="onUpdateWasm"
            >
              <Upload :size="11" /> {{ wasmUpdating ? 'Updating...' : 'Update WASM' }}
            </button>
          </template>
          <template v-else-if="serviceStatus === 'stopped'">
            <button
              class="px-2 py-1 text-[11px] text-green-700 hover:bg-green-50 rounded flex items-center gap-1"
              :disabled="actionLoading"
              @click="onServiceAction('start')"
            >
              <Play :size="11" /> Start
            </button>
          </template>
          <button
            class="px-2 py-1 text-[11px] text-red-500 hover:bg-red-50 rounded flex items-center gap-1"
            :disabled="actionLoading"
            @click="onServiceAction('undeploy')"
          >
            <Trash2 :size="11" /> Undeploy
          </button>
        </template>

        <button
          v-if="isAdmin && isPrimary !== null"
          class="px-2.5 py-1 text-[11px] font-medium rounded flex items-center gap-1 transition-colors ml-2"
          :class="isPrimary
            ? 'bg-amber-100 text-amber-700 hover:bg-amber-200'
            : 'bg-green-100 text-green-700 hover:bg-green-200'"
          :disabled="demotePromoteLoading"
          @click="onDemotePromote"
        >
          {{ demotePromoteLoading ? '...' : isPrimary ? 'Demote' : 'Promote' }}
        </button>

        <div v-if="isAdmin" class="flex items-center gap-1.5 ml-2 pl-2 border-l border-slate-300">
          <span class="text-[10px] font-medium" :class="serverOnline ? 'text-green-600' : 'text-red-500'">
            {{ serverOnline ? 'ONLINE' : 'OFFLINE' }}
          </span>
          <button
            class="relative w-8 h-4 rounded-full transition-colors focus:outline-none"
            :class="serverOnline ? 'bg-green-500' : 'bg-red-400'"
            :disabled="modeLoading"
            @click="onToggleMode"
          >
            <span
              class="absolute top-0.5 w-3 h-3 bg-white rounded-full shadow transition-transform"
              :class="serverOnline ? 'left-4' : 'left-0.5'"
            />
          </button>
        </div>
      </div>
    </div>

    <div class="bg-slate-50 border-b border-slate-200 flex items-center px-3 gap-1">
      <button
        v-for="tab in tabs"
        :key="tab.key"
        class="px-3 py-1.5 text-xs font-medium transition border-b-2 -mb-px"
        :class="activeTab === tab.key
          ? 'text-blue-600 border-blue-600'
          : 'text-slate-500 border-transparent hover:text-slate-700'"
        @click="activeTab = tab.key"
      >{{ tab.label }}</button>
    </div>

    <div v-if="activeTab === 'config'" class="flex-1 overflow-y-auto light-scroll flex flex-col">
      <div class="p-3 border-b border-slate-100 flex items-center gap-2">
        <button
          v-if="isAdmin"
          class="px-2.5 py-1 text-xs rounded flex items-center gap-1 transition"
          :class="configDirty && !configSaving
            ? 'bg-blue-600 text-white hover:bg-blue-700'
            : 'bg-slate-200 text-slate-400 cursor-not-allowed'"
          :disabled="!configDirty || configSaving"
          @click="saveConfig"
        >{{ configSaving ? 'Saving...' : 'Save' }}</button>
        <button
          v-if="isAdmin && configDirty"
          class="px-2.5 py-1 text-xs text-slate-500 hover:bg-slate-100 rounded"
          @click="resetConfig"
        >Reset</button>
        <button
          class="px-2.5 py-1 text-xs text-slate-500 hover:bg-slate-100 rounded"
          @click="loadConfig"
        >&#8635; Refresh</button>
        <span v-if="configSaved" class="text-xs text-green-600">Saved</span>
      </div>

      <div v-if="configLoading" class="p-4 text-xs text-slate-400">Loading...</div>
      <div v-else-if="configError" class="p-4 text-xs text-red-500">{{ configError }}</div>
      <div v-else-if="configForm" class="flex-1 overflow-y-auto p-4 space-y-3">
        <div v-for="section in configSections" :key="section.key" class="border border-slate-200 rounded">
          <div class="px-3 py-1.5 bg-slate-50 border-b border-slate-200 text-xs font-semibold text-slate-600">
            {{ section.label }}
            <span v-if="section.readonly" class="ml-1 text-[10px] font-normal text-slate-400">(read-only)</span>
          </div>
          <div class="px-3 py-2 space-y-2">
            <template v-if="section.fields">
              <div v-for="fk in section.fields" :key="fk" class="flex items-center gap-3">
                <label class="w-36 text-xs text-slate-500 shrink-0">{{ fieldLabel(fk) }}</label>
                <template v-if="fieldType(configForm[fk]) === 'bool'">
                  <input type="checkbox" v-model="configForm[fk]" :disabled="!isAdmin || section.readonly" class="rounded" />
                </template>
                <template v-else>
                  <input
                    :type="fieldType(configForm[fk]) === 'number' ? 'number' : 'text'"
                    :value="configForm[fk]"
                    @input="configForm[fk] = fieldType(configForm[fk]) === 'number' ? Number($event.target.value) : $event.target.value"
                    :disabled="!isAdmin || section.readonly"
                    class="flex-1 px-2 py-1 text-xs border border-slate-200 rounded focus:outline-none focus:ring-1 focus:ring-blue-500 disabled:bg-slate-50 disabled:text-slate-400"
                  />
                </template>
              </div>
            </template>
            <template v-if="section.topFields">
              <div v-for="fk in section.topFields" :key="fk" class="flex items-center gap-3">
                <label class="w-36 text-xs text-slate-500 shrink-0">{{ fieldLabel(fk) }}</label>
                <template v-if="fieldType(configForm[fk]) === 'bool'">
                  <input type="checkbox" v-model="configForm[fk]" :disabled="!isAdmin || section.readonly" class="rounded" />
                </template>
                <template v-else>
                  <input
                    :type="fieldType(configForm[fk]) === 'number' ? 'number' : 'text'"
                    :value="configForm[fk]"
                    @input="configForm[fk] = fieldType(configForm[fk]) === 'number' ? Number($event.target.value) : $event.target.value"
                    :disabled="!isAdmin || section.readonly"
                    class="flex-1 px-2 py-1 text-xs border border-slate-200 rounded focus:outline-none focus:ring-1 focus:ring-blue-500 disabled:bg-slate-50 disabled:text-slate-400"
                  />
                </template>
              </div>
            </template>
        
            <template v-if="section.nested && configForm[section.nested]">
              <template v-for="(val, fk) in configForm[section.nested]" :key="fk">
                <template v-if="fieldType(val) === 'object'">
                  <div class="pt-1 pb-0.5 text-[10px] font-semibold text-slate-400 uppercase tracking-wide">{{ fieldLabel(fk) }}</div>
                  <div v-for="(subVal, subKey) in val" :key="subKey" class="flex items-center gap-3 pl-3">
                    <label class="w-33 text-xs text-slate-500 shrink-0">{{ fieldLabel(subKey) }}</label>
                    <template v-if="fieldType(subVal) === 'bool'">
                      <input type="checkbox" v-model="configForm[section.nested][fk][subKey]" :disabled="!isAdmin || section.readonly" class="rounded" />
                    </template>
                    <template v-else>
                      <input
                        :type="fieldType(subVal) === 'number' ? 'number' : 'text'"
                        :value="subVal"
                        @input="configForm[section.nested][fk][subKey] = fieldType(subVal) === 'number' ? Number($event.target.value) : $event.target.value"
                        :disabled="!isAdmin || section.readonly"
                        class="flex-1 px-2 py-1 text-xs border border-slate-200 rounded focus:outline-none focus:ring-1 focus:ring-blue-500 disabled:bg-slate-50 disabled:text-slate-400"
                      />
                    </template>
                  </div>
                </template>
                <div v-else class="flex items-center gap-3">
                  <label class="w-36 text-xs text-slate-500 shrink-0">{{ fieldLabel(fk) }}</label>
                  <template v-if="fieldType(val) === 'bool'">
                    <input type="checkbox" v-model="configForm[section.nested][fk]" :disabled="!isAdmin || section.readonly" class="rounded" />
                  </template>
                  <template v-else>
                    <input
                      :type="fieldType(val) === 'number' ? 'number' : 'text'"
                      :value="val"
                      @input="configForm[section.nested][fk] = fieldType(val) === 'number' ? Number($event.target.value) : $event.target.value"
                      :disabled="!isAdmin || section.readonly"
                      class="flex-1 px-2 py-1 text-xs border border-slate-200 rounded focus:outline-none focus:ring-1 focus:ring-blue-500 disabled:bg-slate-50 disabled:text-slate-400"
                    />
                  </template>
                </div>
              </template>
            </template>
          </div>
        </div>
      </div>
    </div>

    <div v-if="activeTab === 'schema'" class="flex-1 overflow-y-auto light-scroll">
      <div v-if="canWrite" class="p-3 border-b border-slate-100 flex items-center gap-2">
        <button
          class="px-2.5 py-1 text-xs bg-blue-600 text-white rounded hover:bg-blue-700 flex items-center gap-1"
          @click="onCreateStore()"
        >
          <Plus :size="12" /> Create Store
        </button>
      </div>

      <table class="w-full text-xs">
        <thead>
          <tr class="bg-slate-50 border-b border-slate-200 text-left">
            <th class="px-3 py-1.5 font-medium text-slate-500 w-1/3">Name</th>
            <th class="px-3 py-1.5 font-medium text-slate-500 w-16">Type</th>
            <th class="px-3 py-1.5 font-medium text-slate-500">Details</th>
            <th class="px-3 py-1.5 font-medium text-slate-500 w-24 text-right">Actions</th>
          </tr>
        </thead>
        <tbody>
          <template v-for="store in stores" :key="store.ns">
            <tr class="border-b border-slate-100 hover:bg-slate-50 group">
              <td class="px-3 py-1.5">
                <div class="flex items-center gap-1.5 cursor-pointer" @click="toggleStore(store.ns)">
                  <component
                    :is="store.indexes?.length ? (expandedStores.has(store.ns) ? ChevronDown : ChevronRight) : ChevronRight"
                    :size="12"
                    :class="store.indexes?.length ? 'text-slate-400' : 'text-transparent'"
                  />
                  <Table2 :size="13" class="text-slate-400" />
                  <span class="font-medium text-slate-700">{{ store.short || store.ns }}</span>
                </div>
              </td>
              <td class="px-3 py-1.5 text-slate-400">Store</td>
              <td class="px-3 py-1.5 text-slate-400">
                <span>{{ store.indexes?.length || 0 }} indexes</span>
                <span v-if="store.description" class="ml-2">— {{ store.description }}</span>
              </td>
              <td class="px-3 py-1.5 text-right">
                <div class="flex items-center justify-end gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                  <button v-if="canWrite" class="p-0.5 text-blue-500 hover:bg-blue-50 rounded" title="Create Index" @click="onCreateIndex(store.ns)">
                    <Plus :size="13" />
                  </button>
                  <button class="p-0.5 text-slate-400 hover:bg-slate-100 rounded" title="Export" @click="openExim('export', store)">
                    <Download :size="13" />
                  </button>
                  <button v-if="canWrite" class="p-0.5 text-slate-400 hover:bg-slate-100 rounded" title="Import" @click="openExim('import', store)">
                    <Upload :size="13" />
                  </button>
                  <button v-if="isAdmin" class="p-0.5 text-red-400 hover:bg-red-50 rounded" title="Drop Store" @click="onDrop('store', store.ns)">
                    <Trash2 :size="13" />
                  </button>
                </div>
              </td>
            </tr>

            <template v-if="expandedStores.has(store.ns) && store.indexes?.length">
              <tr v-for="idx in store.indexes" :key="idx.ns" class="border-b border-slate-50 hover:bg-slate-50 group">
                <td class="px-3 py-1">
                  <div class="flex items-center gap-1.5 pl-6">
                    <Key :size="11" :class="idx.unique ? 'text-amber-400' : 'text-slate-300'" />
                    <span class="text-slate-500">{{ idx.short }}</span>
                  </div>
                </td>
                <td class="px-3 py-1 text-slate-400">Index</td>
                <td class="px-3 py-1 text-slate-400">
                  <span class="text-slate-500">{{ idx.field }}</span>
                  <span class="text-slate-300 mx-1">·</span>
                  <span>{{ fieldTypeLabel(idx.field_type) }}</span>
                  <span v-if="idx.unique" class="text-amber-500 ml-1">unique</span>
                  <span v-if="idx.description" class="ml-2">— {{ idx.description }}</span>
                </td>
                <td class="px-3 py-1 text-right">
                  <div v-if="isAdmin" class="flex items-center justify-end opacity-0 group-hover:opacity-100 transition-opacity">
                    <button class="p-0.5 text-red-400 hover:bg-red-50 rounded" title="Drop Index" @click="onDrop('index', idx.ns)">
                      <Trash2 :size="13" />
                    </button>
                  </div>
                </td>
              </tr>
            </template>
          </template>

          <tr v-if="!stores?.length">
            <td colspan="4" class="px-3 py-4 text-center text-slate-400">No stores found</td>
          </tr>
        </tbody>
      </table>
    </div>


    <div v-else-if="activeTab === 'users'" class="flex-1 overflow-y-auto light-scroll">
      <div class="p-3 border-b border-slate-100 flex items-center gap-2">
        <button
          v-if="isAdmin"
          class="px-2.5 py-1 text-xs bg-blue-600 text-white rounded hover:bg-blue-700 flex items-center gap-1"
          @click="showCreateUser = true; createUserError = null; generatedKey = null; newUser = { username: '', role: '2' }"
        >
          <Plus :size="12" /> Create User
        </button>
        <button
          class="px-2.5 py-1 text-xs text-slate-500 hover:bg-slate-100 rounded"
          @click="loadUsers"
        >&#8635; Refresh</button>
      </div>

      <div v-if="usersLoading" class="p-4 text-xs text-slate-400">Loading...</div>
      <div v-else-if="usersError" class="p-4 text-xs text-red-500">{{ usersError }}</div>
      <table v-else class="w-full text-xs">
        <thead>
          <tr class="bg-slate-50 border-b border-slate-200 text-left">
            <th class="px-3 py-1.5 font-medium text-slate-500">Username</th>
            <th class="px-3 py-1.5 font-medium text-slate-500 w-28">Role</th>
            <th class="px-3 py-1.5 font-medium text-slate-500 w-36">Created</th>
            <th v-if="isAdmin" class="px-3 py-1.5 font-medium text-slate-500 w-20 text-right">Actions</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="user in users" :key="user.username" class="border-b border-slate-100 hover:bg-slate-50 group">
            <td class="px-3 py-1.5 text-slate-700 font-medium">{{ user.username }}</td>
            <td class="px-3 py-1.5">
              <select
                v-if="isAdmin && user.username !== 'admin'"
                :value="user.role"
                class="px-1.5 py-0.5 rounded text-[10px] font-medium border-0 cursor-pointer appearance-auto"
                :class="{
                  'bg-red-100 text-red-700': user.role === 'admin',
                  'bg-blue-100 text-blue-700': user.role === 'read_write',
                  'bg-green-100 text-green-700': user.role === 'read_only',
                  'bg-slate-100 text-slate-500': user.role === 'none',
                }"
                @change="onUpdateRole(user.username, $event.target.value)"
              >
                <option value="admin">admin</option>
                <option value="read_write">read_write</option>
                <option value="read_only">read_only</option>
                <option value="none">none</option>
              </select>
              <span v-else class="px-1.5 py-0.5 rounded text-[10px] font-medium"
                :class="{
                  'bg-red-100 text-red-700': user.role === 'admin',
                  'bg-blue-100 text-blue-700': user.role === 'read_write',
                  'bg-green-100 text-green-700': user.role === 'read_only',
                  'bg-slate-100 text-slate-500': user.role === 'none',
                }"
              >{{ user.role }}</span>
            </td>
            <td class="px-3 py-1.5 text-slate-400">{{ formatDate(user.created_at) }}</td>
            <td v-if="isAdmin" class="px-3 py-1.5 text-right">
              <div class="flex items-center justify-end gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                <button class="p-0.5 text-blue-400 hover:bg-blue-50 rounded" title="Regenerate Key" @click="onRegenerateKey(user.username)">
                  <RefreshCw :size="13" />
                </button>
                <button v-if="user.username !== 'admin'" class="p-0.5 text-red-400 hover:bg-red-50 rounded" title="Delete User" @click="onDeleteUser(user.username)">
                  <Trash2 :size="13" />
                </button>
              </div>
            </td>
          </tr>
          <tr v-if="!users.length">
            <td colspan="4" class="px-3 py-4 text-center text-slate-400">No users found</td>
          </tr>
        </tbody>
      </table>
    </div>

    <div v-else-if="activeTab === 'permissions'" class="flex-1 overflow-auto light-scroll">
      <div class="p-3 border-b border-slate-100 flex items-center gap-3">
        <label class="text-xs font-medium text-slate-600">Select User</label>
        <select
          :value="permSelectedUser"
          class="px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500 min-w-[160px]"
          @change="onPermUserChange($event.target.value)"
        >
          <option value="">— choose user —</option>
          <option v-for="u in permUserList" :key="u" :value="u">{{ u }}</option>
        </select>
        <button
          class="px-2.5 py-1 text-xs text-slate-500 hover:bg-slate-100 rounded"
          @click="loadPermissions"
        >&#8635; Refresh</button>
      </div>

      <div v-if="permLoading" class="p-4 text-xs text-slate-400">Loading permissions...</div>
      <div v-else-if="permError" class="p-4 text-xs text-red-500">{{ permError }}</div>
      <div v-else-if="!permSelectedUser" class="p-4 text-xs text-slate-400">Select a user to manage service permissions.</div>
      <div v-else-if="permServices.length === 0" class="p-4 text-xs text-slate-400">No services found.</div>

      <table v-else class="w-full text-xs">
        <thead>
          <tr class="bg-slate-50 border-b border-slate-200 text-left">
            <th class="px-3 py-1.5 font-medium text-slate-500">Service</th>
            <th class="px-3 py-1.5 font-medium text-slate-500 w-[280px]">Key</th>
            <th class="px-3 py-1.5 font-medium text-slate-500 w-32">Permission</th>
          </tr>
        </thead>
        <tbody>
          <tr
            v-for="svc in permServices"
            :key="svc.name"
            class="border-b border-slate-100 hover:bg-slate-50"
          >
            <td class="px-3 py-1.5 text-slate-700 font-medium">
              {{ svc.name }}
              <span v-if="!svc.connected" class="text-[10px] text-slate-400 ml-1">(not connected)</span>
            </td>

            <td class="px-3 py-1.5">
              <template v-if="permRows[svc.name]?.key">
                <div class="flex items-center gap-1">
                  <code class="text-[10px] font-mono text-slate-600 bg-slate-50 px-1.5 py-0.5 rounded border border-slate-200 truncate max-w-[220px] select-all">{{ permRows[svc.name].key }}</code>
                  <button
                    class="p-0.5 rounded hover:bg-slate-200 text-slate-400 hover:text-slate-600 shrink-0 transition-colors"
                    :title="permCopied === svc.name ? 'Copied!' : 'Copy key'"
                    @click="permCopyKey(svc.name)"
                  >
                    <svg v-if="permCopied === svc.name" xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="text-green-500"><polyline points="20 6 9 17 4 12"/></svg>
                    <svg v-else xmlns="http://www.w3.org/2000/svg" width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/></svg>
                  </button>
                </div>
              </template>
              <span v-else class="text-[10px] text-slate-300">—</span>
            </td>

            <td class="px-3 py-1.5">
              <template v-if="svc.connected">
                <select
                  :value="permRows[svc.name]?.role || 'none'"
                  :disabled="permSaving[svc.name]"
                  class="px-1.5 py-0.5 rounded text-[10px] font-medium border-0 cursor-pointer appearance-auto"
                  :class="{
                    'bg-red-100 text-red-700': permRows[svc.name]?.role === 'admin',
                    'bg-blue-100 text-blue-700': permRows[svc.name]?.role === 'read_write',
                    'bg-green-100 text-green-700': permRows[svc.name]?.role === 'read_only',
                    'bg-slate-100 text-slate-500': !permRows[svc.name]?.role || permRows[svc.name]?.role === 'none',
                  }"
                  @change="permSetRole(svc.name, $event.target.value)"
                >
                  <option value="admin">admin</option>
                  <option value="read_write">read_write</option>
                  <option value="read_only">read_only</option>
                  <option value="none">none</option>
                </select>
              </template>
              <span v-else class="text-[10px] text-slate-300">—</span>
            </td>
          </tr>
        </tbody>
      </table>
    </div>


    <ConfirmDialog
      v-if="confirmDialog"
      title="Confirm"
      :message="`Are you sure you want to delete '${confirmDialog.label}'?`"
      confirm-label="Delete"
      :loading="confirmLoading"
      @confirm="handleConfirm"
      @close="confirmDialog = null"
    />

    <ConfirmDropDialog
      v-if="dropDialog"
      :type="dropDialog.type"
      :ns="dropDialog.ns"
      :service-name="serviceName"
      @close="dropDialog = null"
      @dropped="onDropped"
    />

    <CreateStoreDialog
      v-if="createDialog?.type === 'create-store'"
      :service-name="serviceName"
      @close="createDialog = null"
      @created="onDialogCreated"
    />
    <CreateIndexDialog
      v-if="createDialog?.type === 'create-index'"
      :service-name="serviceName"
      :store-ns="createDialog.storeNs"
      @close="createDialog = null"
      @created="onDialogCreated"
    />

    <Modal v-if="showCreateUser" title="Create User" @close="showCreateUser = false; generatedKey = null">
      <div class="space-y-3">
        <div v-if="generatedKey" class="p-3 bg-green-50 border border-green-200 rounded">
          <p class="text-xs font-medium text-green-800 mb-1">User created. Save this connection key now - it cannot be retrieved later:</p>
          <div class="flex items-center gap-2">
            <code class="flex-1 text-xs bg-white px-2 py-1.5 rounded border border-green-300 font-mono select-all break-all">{{ generatedKey }}</code>
            <button class="px-2 py-1 text-xs bg-green-600 text-white rounded hover:bg-green-700 shrink-0" @click="copyToClipboard(generatedKey)">Copy</button>
          </div>
        </div>
        <template v-else>
          <div>
            <label class="block text-xs font-medium text-slate-600 mb-1">Username</label>
            <input v-model="newUser.username" type="text" class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500" />
          </div>
          <div>
            <label class="block text-xs font-medium text-slate-600 mb-1">Role</label>
            <select v-model="newUser.role" class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500">
              <option value="0">admin</option>
              <option value="1">read_write</option>
              <option value="2">read_only</option>
              <option value="3">none</option>
            </select>
          </div>
          <p v-if="createUserError" class="text-xs text-red-500">{{ createUserError }}</p>
        </template>
      </div>
      <template #footer>
        <template v-if="generatedKey">
          <button class="px-3 py-1.5 text-xs bg-blue-600 text-white rounded hover:bg-blue-700" @click="showCreateUser = false; generatedKey = null">Done</button>
        </template>
        <template v-else>
          <button class="px-3 py-1.5 text-xs text-slate-600 hover:bg-slate-100 rounded" @click="showCreateUser = false">Cancel</button>
          <button
            class="px-3 py-1.5 text-xs bg-blue-600 text-white rounded hover:bg-blue-700"
            :disabled="createUserLoading"
            @click="onCreateUser"
          >{{ createUserLoading ? 'Creating...' : 'Create' }}</button>
        </template>
      </template>
    </Modal>

    <Modal v-if="regeneratedKey" title="Key Regenerated" @close="regeneratedKey = null">
      <div class="p-3 bg-green-50 border border-green-200 rounded">
        <p class="text-xs font-medium text-green-800 mb-1">New key for <strong>{{ regeneratedUser }}</strong>. Save it now - it cannot be retrieved later:</p>
        <div class="flex items-center gap-2">
          <code class="flex-1 text-xs bg-white px-2 py-1.5 rounded border border-green-300 font-mono select-all break-all">{{ regeneratedKey }}</code>
          <button class="px-2 py-1 text-xs bg-green-600 text-white rounded hover:bg-green-700 shrink-0" @click="copyToClipboard(regeneratedKey)">Copy</button>
        </div>
      </div>
      <template #footer>
        <button class="px-3 py-1.5 text-xs bg-blue-600 text-white rounded hover:bg-blue-700" @click="regeneratedKey = null">Done</button>
      </template>
    </Modal>

    <ExportDialog v-if="showExportDialog" :service-name="serviceName" :store-name="eximStore" @close="showExportDialog = false" @done="emit('schema-changed')" />
    <ImportDialog v-if="showImportDialog" :service-name="serviceName" :store-name="eximStore" @close="showImportDialog = false" @done="emit('schema-changed')" />
  </div>
</template>
