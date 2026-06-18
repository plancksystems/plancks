<script setup>
import { ref, computed, watch, nextTick } from 'vue'
import { connectDb, disconnectDb, executeQuery } from '../api'
import { Play, Plus, X, LogIn, LogOut } from 'lucide-vue-next'
import QueryEditor from './QueryEditor.vue'
import ResultsPanel from './ResultsPanel.vue'
import Modal from './Modal.vue'

const props = defineProps({
  services: { type: Array, default: () => [] },
  databases: { type: Array, default: () => [] },
  openRequest: { type: Object, default: null },
})

const emit = defineEmits(['refresh-databases', 'schema-loaded', 'navigate'])

let nextId = 1
const tabs = ref([createTab()])
const activeTabId = ref(tabs.value[0].id)

const showConnectModal = ref(false)
const connectForm = ref({ uid: '', key: '' })
const connectError = ref(null)
const connectLoading = ref(false)

const showNewKeyModal = ref(false)
const newAdminKey = ref('')


const activeTab = computed(() => tabs.value.find(t => t.id === activeTabId.value) || tabs.value[0])

const activeDbInfo = computed(() => {
  const tab = activeTab.value
  if (!tab?.serviceName) return null
  return props.databases.find(d => d.name === tab.serviceName) || null
})

const isConnected = computed(() => activeDbInfo.value?.connected === true)

watch(() => props.openRequest, (req) => {
  if (!req) return
  openServiceTab(req.serviceName, req.storeNs, req.appName)
}, { deep: true })

function createTab(serviceName, storeNs, appName) {
  const id = nextId++
  return {
    id,
    serviceName: serviceName || null,
    appName: appName || null,
    queryText: storeNs ? storeNs + '.limit(10)' : '',
    results: null,
    status: { state: 'ready', text: 'Ready' },
    editorRef: null,
  }
}

function isServiceConnected(serviceName) {
  const db = props.databases.find(d => d.name === serviceName)
  return db?.connected === true
}

async function tryAutoConnect(serviceName) {
  if (!serviceName || isServiceConnected(serviceName)) return
  try {
    await connectDb(serviceName, '', '')
    emit('refresh-databases')
  } catch {
    nextTick(() => openConnectModal())
  }
}

function openServiceTab(serviceName, storeNs, appName) {
  if (serviceName) {
    const existing = tabs.value.find(t => t.serviceName === serviceName)
    if (existing) {
      activeTabId.value = existing.id
      if (storeNs) existing.queryText = storeNs + '.limit(10)'
      if (appName) existing.appName = appName
      tryAutoConnect(serviceName)
      return
    }
  }

  const emptyTab = tabs.value.find(t => !t.serviceName)
  if (emptyTab) {
    emptyTab.serviceName = serviceName
    emptyTab.appName = appName || null
    if (storeNs) emptyTab.queryText = storeNs + '.limit(10)'
    activeTabId.value = emptyTab.id
    tryAutoConnect(serviceName)
    return
  }

  const tab = createTab(serviceName, storeNs, appName)
  tabs.value.push(tab)
  activeTabId.value = tab.id
  tryAutoConnect(serviceName)
}

function addNewTab() {
  const tab = createTab()
  tabs.value.push(tab)
  activeTabId.value = tab.id
}

function closeTab(id) {
  if (tabs.value.length <= 1) return
  const idx = tabs.value.findIndex(t => t.id === id)
  tabs.value = tabs.value.filter(t => t.id !== id)
  if (activeTabId.value === id) {
    activeTabId.value = tabs.value[Math.min(idx, tabs.value.length - 1)].id
  }
}

function selectService(serviceName) {
  const tab = activeTab.value
  if (!tab) return
  if (tab.serviceName && tab.serviceName !== serviceName) {
    openServiceTab(serviceName)
  } else {
    tab.serviceName = serviceName
  }
}

function tabLabel(tab) {
  if (!tab.serviceName) return 'New Tab'
  if (tab.appName) return `${tab.appName} / ${tab.serviceName}`
  return tab.serviceName
}

function getActiveQuery(tab) {
  const textarea = tab.editorRef?.getTextarea?.()
  const full = tab.queryText
  if (textarea) {
    const selected = textarea.value.substring(textarea.selectionStart, textarea.selectionEnd).trim()
    if (selected) return selected
  }
  if (!full.trim()) return ''
  if (textarea) {
    const cursor = textarea.selectionStart
    const before = full.substring(0, cursor)
    const after = full.substring(cursor)
    const lastSemi = before.lastIndexOf(';')
    const nextSemi = after.indexOf(';')
    const start = lastSemi === -1 ? 0 : lastSemi + 1
    const end = nextSemi === -1 ? full.length : cursor + nextSemi
    const segment = full.substring(start, end).trim()
    if (segment) return segment
  }
  const queries = full.split(';').map(s => s.trim()).filter(Boolean)
  return queries[0] || full.trim()
}

async function onExecute() {
  const tab = activeTab.value
  if (!tab?.serviceName) return
  if (tab.status.state === 'running') return
  const q = getActiveQuery(tab)
  if (!q) { tab.status = { state: 'error', text: 'No query entered' }; return }

  const limitMatch = q.match(/\.limit\(\s*(\d+)\s*\)/i)
  if (limitMatch && parseInt(limitMatch[1]) > 10000) {
    tab.status = { state: 'error', text: 'Error' }
    tab.results = { error: 'Limit exceeds 10000. Use limit(10000) or less.' }
    return
  }

  tab.status = { state: 'running', text: 'Executing...' }
  const startTime = performance.now()
  try {
    const { result, bytes } = await executeQuery(q, tab.serviceName)
    const elapsed = ((performance.now() - startTime) / 1000).toFixed(3)
    if (result.success) {
      const data = result.data || []
      const count = Array.isArray(data) ? data.length : 0
      tab.status = { state: 'ready', text: `${count} rows | ${formatSize(bytes)} | ${elapsed}s` }
      tab.results = { data }
    } else {
      tab.status = { state: 'error', text: 'Error' }
      tab.results = { error: result.error || 'Query failed', raw: result }
    }
  } catch (e) {
    tab.status = { state: 'error', text: 'Error' }
    tab.results = { error: e.message }
  }
}

function formatSize(bytes) {
  if (bytes < 1024) return bytes + ' B'
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB'
  return (bytes / (1024 * 1024)).toFixed(2) + ' MB'
}

function openConnectModal() {
  connectForm.value = { uid: '', key: '' }
  connectError.value = null
  showConnectModal.value = true
}

async function onConnect() {
  const tab = activeTab.value
  if (!tab?.serviceName) return
  connectError.value = null
  if (!connectForm.value.uid.trim()) { connectError.value = 'UID is required'; return }
  if (!connectForm.value.key.trim()) { connectError.value = 'Key is required'; return }

  connectLoading.value = true
  try {
    const result = await connectDb(tab.serviceName, connectForm.value.uid, connectForm.value.key)
    showConnectModal.value = false
    emit('refresh-databases')
    if (result.newKey) {
      newAdminKey.value = result.newKey
      showNewKeyModal.value = true
    }
  } catch (e) {
    connectError.value = e.message
  } finally {
    connectLoading.value = false
  }
}

async function onDisconnect() {
  const tab = activeTab.value
  if (!tab?.serviceName) return
  try {
    await disconnectDb(tab.serviceName)
    emit('refresh-databases')
  } catch (e) {
    alert('Disconnect failed: ' + e.message)
  }
}

defineExpose({ openServiceTab })
</script>

<template>
  <div class="flex-1 flex flex-col min-w-0 overflow-hidden">
    <div class="bg-slate-50 border-b border-slate-200 shrink-0 flex items-center px-1 h-9">
      <div class="flex items-center gap-0 overflow-x-auto min-w-0">
        <div
          v-for="tab in tabs"
          :key="tab.id"
          class="flex items-center gap-1 px-2.5 py-1 text-xs cursor-pointer border-b-2 shrink-0 group"
          :class="tab.id === activeTabId
            ? 'border-blue-600 text-blue-700 bg-white'
            : 'border-transparent text-slate-500 hover:text-slate-700 hover:bg-slate-100'"
          @click="activeTabId = tab.id"
        >
          <span
            class="w-1.5 h-1.5 rounded-full shrink-0"
            :class="tab.serviceName && databases.find(d => d.name === tab.serviceName)?.connected ? 'bg-green-500' : 'bg-slate-300'"
          />
          <span class="font-medium truncate max-w-[120px]">{{ tabLabel(tab) }}</span>
          <button
            v-if="tabs.length > 1"
            class="ml-0.5 p-0.5 rounded hover:bg-slate-200 text-slate-400 hover:text-slate-600 opacity-0 group-hover:opacity-100 transition-opacity"
            @click.stop="closeTab(tab.id)"
          >
            <X :size="10" />
          </button>
        </div>
      </div>

      <button
        class="p-1 text-slate-400 hover:text-slate-600 hover:bg-slate-100 rounded shrink-0 ml-0.5"
        title="New tab"
        @click="addNewTab"
      >
        <Plus :size="13" />
      </button>

      <div class="flex-1" />

      <div class="flex items-center gap-2 shrink-0">
        <template v-if="activeTab.serviceName">
          <template v-if="isConnected">
            <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-green-100 text-green-700">
              <span class="w-1.5 h-1.5 rounded-full bg-green-500" />
              {{ activeDbInfo?.uid || '' }} ({{ activeDbInfo?.role || '' }})
            </span>
            <button
              class="px-1.5 py-0.5 text-[10px] text-slate-500 hover:bg-slate-200 rounded flex items-center gap-1"
              @click="onDisconnect"
            >
              <LogOut :size="10" /> Disconnect
            </button>
          </template>
          <template v-else>
            <button
              class="px-2 py-0.5 text-[10px] bg-blue-600 text-white rounded hover:bg-blue-700 flex items-center gap-1"
              @click="openConnectModal"
            >
              <LogIn :size="10" /> Connect
            </button>
          </template>
        </template>
      </div>
    </div>

    <template v-if="activeTab.serviceName && isConnected">
      <div class="bg-slate-100 border-b border-slate-200 flex items-center px-2 py-0.5 shrink-0 gap-1">
        <button
          class="p-1.5 bg-blue-600 text-white rounded hover:bg-blue-700 shrink-0 disabled:bg-blue-400 disabled:cursor-not-allowed"
          @click="onExecute"
          :disabled="activeTab.status.state === 'running'"
          :title="activeTab.status.state === 'running' ? 'Query in flight…' : 'Execute (Ctrl+R / Cmd+R)'"
        >
          <Play v-if="activeTab.status.state !== 'running'" :size="13" />
          <span v-else class="inline-block w-3 h-3 border-2 border-white border-t-transparent rounded-full animate-spin"></span>
        </button>
        <div class="ml-auto flex gap-1.5 items-center">
          <span class="inline-block w-2 h-2 rounded-full"
            :class="{
              'bg-yellow-500 animate-pulse': activeTab.status.state === 'running',
              'bg-red-500': activeTab.status.state === 'error',
              'bg-green-500': activeTab.status.state === 'ready',
            }"
          />
          <span class="text-[11px] font-medium"
            :class="{
              'text-yellow-700': activeTab.status.state === 'running',
              'text-red-700': activeTab.status.state === 'error',
              'text-green-700': activeTab.status.state === 'ready',
            }"
          >{{ activeTab.status.text }}</span>
        </div>
      </div>

      <QueryEditor :ref="el => { if (el) activeTab.editorRef = el }" v-model="activeTab.queryText" @execute="onExecute" />
      <ResultsPanel :results="activeTab.results" />
    </template>

    <div v-else-if="activeTab.serviceName && !isConnected" class="flex-1 flex items-center justify-center">
      <div class="text-center">
        <div class="text-slate-400 text-sm mb-3">Connect to <span class="font-medium text-slate-600">{{ activeTab.serviceName }}</span> to start querying</div>
        <button class="px-4 py-2 bg-blue-600 text-white text-sm rounded hover:bg-blue-700 flex items-center gap-2 mx-auto" @click="openConnectModal">
          <LogIn :size="16" /> Connect
        </button>
      </div>
    </div>

    <div v-else class="flex-1 flex items-center justify-center">
      <div class="text-center">
        <div class="text-slate-400 text-sm mb-3">Select a service to start querying</div>
        <select
          class="text-sm bg-white border border-slate-300 rounded px-3 py-2 focus:outline-none focus:border-blue-500"
          @change="selectService($event.target.value); $event.target.value = ''"
        >
          <option value="" disabled selected>Choose a service...</option>
          <option v-for="svc in services" :key="svc.name" :value="svc.name">{{ svc.name }}</option>
        </select>
      </div>
    </div>

    <Modal v-if="showConnectModal" title="Connect to Service" @close="showConnectModal = false">
      <div class="space-y-3">
        <div class="text-xs text-slate-500">Service: <span class="font-medium text-slate-700">{{ activeTab.serviceName }}</span></div>
        <div v-if="connectError" class="p-2 bg-red-50 border border-red-200 rounded text-xs text-red-600">{{ connectError }}</div>
        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">UID</label>
          <input v-model="connectForm.uid" type="text" class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500" placeholder="admin" autofocus />
        </div>
        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">Key</label>
          <input v-model="connectForm.key" type="password" class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500 font-mono" placeholder="base64 key" @keyup.enter="onConnect" />
        </div>
      </div>
      <template #footer>
        <button class="px-3 py-1.5 text-xs text-slate-600 hover:bg-slate-100 rounded" @click="showConnectModal = false">Cancel</button>
        <button class="px-3 py-1.5 text-xs bg-blue-600 text-white rounded hover:bg-blue-700 disabled:opacity-50" :disabled="connectLoading" @click="onConnect">
          {{ connectLoading ? 'Connecting...' : 'Connect' }}
        </button>
      </template>
    </Modal>

    <Modal v-if="showNewKeyModal" title="Admin Key Regenerated" @close="showNewKeyModal = false">
      <div class="space-y-3">
        <div class="p-2 bg-amber-50 border border-amber-200 rounded text-xs text-amber-700">
          Your admin key has been automatically regenerated. Save the new key below.
        </div>
        <div class="flex gap-1">
          <input :value="newAdminKey" readonly class="flex-1 px-2 py-1.5 text-xs border border-slate-300 rounded bg-slate-50 font-mono select-all" @focus="$event.target.select()" />
          <button class="px-2 py-1.5 text-xs bg-slate-200 hover:bg-slate-300 rounded" @click="navigator.clipboard.writeText(newAdminKey)">Copy</button>
        </div>
      </div>
      <template #footer>
        <button class="px-3 py-1.5 text-xs bg-blue-600 text-white rounded hover:bg-blue-700" @click="showNewKeyModal = false">I've saved the key</button>
      </template>
    </Modal>
  </div>
</template>
