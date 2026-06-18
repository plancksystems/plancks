<script setup>
import { ref, watch, computed, onMounted } from 'vue'
import { connectDb, disconnectDb, fetchLeftPane, executeQuery } from '../api'
import { Play, LogIn, LogOut } from 'lucide-vue-next'
import QueryEditor from './QueryEditor.vue'
import ResultsPanel from './ResultsPanel.vue'
import ServerOverviewPanel from './ServerOverviewPanel.vue'
import ServiceDashboard from './ServiceDashboard.vue'
import Modal from './Modal.vue'
import ExportDialog from './ExportDialog.vue'
import ImportDialog from './ImportDialog.vue'

const props = defineProps({
  serviceName: { type: String, required: true },
  serviceInfo: { type: Object, default: null },
  databases: { type: Array, default: () => [] },
  view: { type: String, default: 'overview' },
  storeNs: { type: String, default: null },
})

const emit = defineEmits(['refresh-databases', 'schema-loaded', 'service-action', 'navigate'])

const activeTab = ref('query')

const tabs = [
  { key: 'query', label: 'Query Editor' },
  { key: 'schema', label: 'Schema' },
  { key: 'config', label: 'Config' },
]

const connected = ref(false)
const role = ref('')
const uid = ref('')
const stores = ref([])

const canWrite = computed(() => role.value === 'admin' || role.value === 'read_write')

const queryText = ref('')
const status = ref({ state: 'ready', text: 'Ready' })
const results = ref(null)
const editorRef = ref(null)

const showConnectModal = ref(false)
const connectForm = ref({ uid: '', key: '' })
const connectError = ref(null)
const connectLoading = ref(false)

const showNewKeyModal = ref(false)
const newAdminKey = ref('')

const currentDb = computed(() => props.databases.find(d => d.name === props.serviceName) || null)

watch(() => props.serviceName, () => {
  checkConnection()
})

watch(() => props.storeNs, (ns) => {
  if (ns) {
    queryText.value = ns + '.limit(10)'
  }
})

onMounted(() => {
  checkConnection()
  if (props.storeNs) {
    queryText.value = props.storeNs + '.limit(10)'
  }
})

function checkConnection() {
  const db = currentDb.value
  if (db?.connected) {
    connected.value = true
    role.value = db.role || ''
    uid.value = db.uid || ''
    loadSchema()
  } else {
    connected.value = false
    role.value = ''
    uid.value = ''
    stores.value = []
  }
}

async function loadSchema() {
  if (!connected.value) { stores.value = []; return }
  try {
    const data = await fetchLeftPane(props.serviceName)
    stores.value = data.stores || []
    emit('schema-loaded', props.serviceName, stores.value)
  } catch {
    stores.value = []
  }
}

function openConnectModal() {
  connectForm.value = { uid: '', key: '' }
  connectError.value = null
  showConnectModal.value = true
}

async function onConnect() {
  connectError.value = null
  if (!connectForm.value.uid.trim()) { connectError.value = 'UID is required'; return }
  if (!connectForm.value.key.trim()) { connectError.value = 'Key is required'; return }

  connectLoading.value = true
  try {
    const result = await connectDb(props.serviceName, connectForm.value.uid, connectForm.value.key)
    showConnectModal.value = false
    emit('refresh-databases')
    connected.value = true
    role.value = result.role || ''
    uid.value = connectForm.value.uid
    loadSchema()
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
  try {
    await disconnectDb(props.serviceName)
    emit('refresh-databases')
    connected.value = false
    role.value = ''
    uid.value = ''
    stores.value = []
  } catch (e) {
    alert('Disconnect failed: ' + e.message)
  }
}

function getActiveQuery() {
  const textarea = editorRef.value?.getTextarea?.()
  if (textarea) {
    const selected = textarea.value.substring(textarea.selectionStart, textarea.selectionEnd).trim()
    if (selected) return selected
  }
  const full = queryText.value
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
  const q = getActiveQuery()
  if (!q) { status.value = { state: 'error', text: 'No query entered' }; return }

  const limitMatch = q.match(/\.limit\(\s*(\d+)\s*\)/i)
  if (limitMatch && parseInt(limitMatch[1]) > 10000) {
    status.value = { state: 'error', text: 'Error' }
    results.value = { error: 'Limit exceeds 10000. Use limit(10000) or less.' }
    return
  }

  status.value = { state: 'running', text: 'Executing...' }
  const startTime = performance.now()
  try {
    const { result, bytes } = await executeQuery(q, props.serviceName)
    const elapsed = ((performance.now() - startTime) / 1000).toFixed(3)
    if (result.success) {
      const data = result.data || []
      const count = Array.isArray(data) ? data.length : 0
      status.value = { state: 'ready', text: `${count} rows | ${formatSize(bytes)} | ${elapsed}s` }
      results.value = { data }
    } else {
      status.value = { state: 'error', text: 'Error' }
      results.value = { error: result.error || 'Query failed', raw: result }
    }
  } catch (e) {
    status.value = { state: 'error', text: 'Error' }
    results.value = { error: e.message }
  }
}

function formatSize(bytes) {
  if (bytes < 1024) return bytes + ' B'
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB'
  return (bytes / (1024 * 1024)).toFixed(2) + ' MB'
}

const showExportDialog = ref(false)
const showImportDialog = ref(false)
const eximStore = ref('')

function onContextAction(action) {
  if (action.type === 'export') {
    eximStore.value = action.store?.ns || ''
    showExportDialog.value = true
  } else if (action.type === 'import') {
    eximStore.value = action.store?.ns || ''
    showImportDialog.value = true
  }
}
</script>

<template>
  <div class="flex-1 flex flex-col min-w-0 overflow-hidden">
    <div class="bg-slate-50 border-b border-slate-200 shrink-0 px-4 flex items-center">
      <div class="flex gap-0">
        <button
          v-for="tab in tabs"
          :key="tab.key"
          class="px-3 py-2 text-xs font-medium border-b-2 transition-colors"
          :class="activeTab === tab.key
            ? 'border-blue-600 text-blue-700'
            : 'border-transparent text-slate-500 hover:text-slate-700 hover:border-slate-300'"
          @click="activeTab = tab.key"
        >
          {{ tab.label }}
        </button>
      </div>
      <div class="ml-auto flex items-center gap-2">
        <template v-if="connected">
          <span v-if="!canWrite" class="text-[10px] px-2 py-0.5 rounded bg-amber-100 text-amber-700 font-medium">Read-only</span>
          <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-green-100 text-green-700">
            <span class="w-1.5 h-1.5 rounded-full bg-green-500" />
            {{ uid }} ({{ role }})
          </span>
          <button class="px-2 py-1 text-xs text-slate-500 hover:bg-slate-200 rounded flex items-center gap-1" @click="onDisconnect">
            <LogOut :size="12" /> Disconnect
          </button>
        </template>
        <template v-else>
          <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-slate-200 text-slate-500">
            <span class="w-1.5 h-1.5 rounded-full bg-slate-400" />
            Not connected
          </span>
          <button class="px-2.5 py-1 text-xs bg-blue-600 text-white rounded hover:bg-blue-700 flex items-center gap-1" @click="openConnectModal">
            <LogIn :size="12" /> Connect
          </button>
        </template>
      </div>
    </div>

    <template v-if="activeTab === 'query'">
      <template v-if="connected">
        <div class="bg-slate-100 border-b border-slate-200 flex items-center px-3 py-1 shrink-0">
          <button class="p-1.5 bg-blue-600 text-white rounded hover:bg-blue-700" @click="onExecute" title="Execute (Ctrl+R / Cmd+R)">
            <Play :size="14" />
          </button>
          <div class="ml-auto flex gap-1.5 items-center">
            <span class="inline-block w-2 h-2 rounded-full"
              :class="{
                'bg-yellow-500 animate-pulse': status.state === 'running',
                'bg-red-500': status.state === 'error',
                'bg-green-500': status.state === 'ready',
              }"
            />
            <span class="text-xs font-medium"
              :class="{
                'text-yellow-700': status.state === 'running',
                'text-red-700': status.state === 'error',
                'text-green-700': status.state === 'ready',
              }"
            >{{ status.text }}</span>
          </div>
        </div>
        <QueryEditor ref="editorRef" v-model="queryText" @execute="onExecute" />
        <ResultsPanel :results="results" />
      </template>
      <div v-else class="flex-1 flex items-center justify-center">
        <div class="text-center">
          <div class="text-slate-400 text-sm mb-3">Connect to start querying this service</div>
          <button class="px-4 py-2 bg-blue-600 text-white text-sm rounded hover:bg-blue-700 flex items-center gap-2 mx-auto" @click="openConnectModal">
            <LogIn :size="16" /> Connect
          </button>
        </div>
      </div>
    </template>

    <template v-else-if="activeTab === 'schema'">
      <template v-if="connected">
        <ServerOverviewPanel
          :stores="stores"
          :service-name="serviceName"
          :db-name="serviceName"
          :role="role"
          :service-status="serviceInfo?.status || ''"
          @schema-changed="loadSchema"
          @service-action="(action) => emit('service-action', action)"
          @context-action="onContextAction"
        />
      </template>
      <div v-else class="flex-1 flex items-center justify-center">
        <div class="text-slate-400 text-sm">Connect to browse schema</div>
      </div>
    </template>

    <template v-else-if="activeTab === 'config'">
      <ServiceDashboard
        :service-name="serviceName"
        :service-info="serviceInfo"
      />
    </template>

    <Modal v-if="showConnectModal" title="Connect to Service" @close="showConnectModal = false">
      <div class="space-y-3">
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

    <ExportDialog v-if="showExportDialog" :service-name="serviceName" :store-name="eximStore" @close="showExportDialog = false" @done="loadSchema()" />
    <ImportDialog v-if="showImportDialog" :service-name="serviceName" :store-name="eximStore" @close="showImportDialog = false" @done="loadSchema()" />

  </div>
</template>
