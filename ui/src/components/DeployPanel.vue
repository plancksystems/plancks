<script setup>
import { ref, computed } from 'vue'
import { deployService, createApp } from '../api'
import { Rocket, Upload, Database, HardDrive, ChevronLeft } from 'lucide-vue-next'

const props = defineProps({
  apps: { type: Array, default: () => [] },
})

const emit = defineEmits(['navigate', 'apps-changed'])

const selectedApp = ref('')
const showNewApp = ref(false)
const newAppName = ref('')
const newAppDesc = ref('')

const activeTab = ref('manifest')

const tabs = [
  { key: 'manifest', label: 'Deploy Manifest', icon: Database },
  { key: 'backup', label: 'Deploy from Backup', icon: HardDrive },
]

const DEFAULT_ADMIN_KEY = 'UGxhbmNrX0RlZmF1bHRfQWRtaW5fS2V5XzAwMTA='

const form = ref({
  name: '',
  description: '',
  admin_uid: 'admin',
  admin_key: DEFAULT_ADMIN_KEY,
})

const configYaml = ref('')

const restorePath = ref('')

const deploying = ref(false)
const deployError = ref('')
const deploySuccess = ref('')
const deployLog = ref([])

const replicaEnabled = computed(() => {
  if (!configYaml.value) return false
  return parseReplicaEnabled(configYaml.value)
})


function parseReplicaEnabled(yaml) {
  const replicaMatch = yaml.match(/^replica:\s*$/m)
  if (!replicaMatch) return false
  const afterReplica = yaml.substring(replicaMatch.index + replicaMatch[0].length)
  const enabledMatch = afterReplica.match(/^\s+enabled:\s*(true|false)/m)
  if (!enabledMatch) return false
  return enabledMatch[1] === 'true'
}

function parseYamlField(yaml, field) {
  const re = new RegExp(`^${field}:\\s*(.+)$`, 'm')
  const m = yaml.match(re)
  return m ? m[1].trim().replace(/^["']|["']$/g, '') : null
}

function replaceYamlField(yaml, field, newValue) {
  const re = new RegExp(`^(${field}:\\s*)(.+)$`, 'm')
  return yaml.replace(re, `$1${newValue}`)
}

function makeReplicaYaml(yaml, role, serviceName) {
  let modified = yaml
  const origPort = parseYamlField(yaml, 'port')
  const replicaPortMatch = yaml.match(/^(\s+)port:\s*(\d+)/m)
  const replicaPort = replicaPortMatch ? replicaPortMatch[2] : null

  if (role === 'cmd') {
    modified = replaceYamlField(modified, 'service_type', 'command')
  } else {
    modified = replaceYamlField(modified, 'service_type', 'query')
    if (origPort && replicaPort) {
      modified = replaceYamlField(modified, 'port', replicaPort)
      modified = modified.replace(
        /^(\s+port:\s*)\d+/m,
        `$1${origPort}`
      )
    }
  }

  const baseDirMatch = modified.match(/^(base_dir:\s*["']?)(.+?)(["']?\s*)$/m)
  if (baseDirMatch) {
    const origDir = baseDirMatch[2]
    const newDir = origDir.replace(/[^/]+$/, serviceName)
    modified = modified.replace(
      /^(base_dir:\s*["']?).+?(["']?\s*)$/m,
      `$1${newDir}$2`
    )
  }

  return modified
}

async function onFileUpload(e) {
  const file = e.target.files?.[0]
  if (!file) return
  configYaml.value = await file.text()
  if (!form.value.name && file.name) {
    form.value.name = file.name.replace(/\.(ya?ml)$/i, '')
  }
}

async function onDeploy() {
  deployError.value = ''
  deploySuccess.value = ''
  deployLog.value = []

  if (!selectedApp.value) { deployError.value = 'Please select an app'; return }
  if (!form.value.name.trim()) { deployError.value = 'Service name is required'; return }

  if (activeTab.value === 'manifest') {
    if (!configYaml.value.trim()) { deployError.value = 'Config YAML is required - upload a .yaml file'; return }
  }

  if (activeTab.value === 'backup') {
    if (!restorePath.value.trim()) { deployError.value = 'Backup path is required'; return }
  }

  deploying.value = true

  try {
    const baseName = form.value.name.trim()
    const yaml = activeTab.value === 'backup' ? '' : configYaml.value.trim()
    const useReplica = replicaEnabled.value && activeTab.value !== 'backup'

    if (useReplica) {
      const cmdName = baseName + '.db.command'
      const cmdYaml = makeReplicaYaml(yaml, 'cmd', cmdName)
      deployLog.value.push(`Deploying ${cmdName}...`)
      await deployService({
        app: selectedApp.value,
        name: cmdName,
        config_yaml: cmdYaml,
        admin_uid: form.value.admin_uid.trim() || 'admin',
        admin_key: DEFAULT_ADMIN_KEY,
        description: form.value.description.trim(),
      })
      deployLog.value.push(`Command node deployed`)
      deployLog.value.push(`Query replica forwarded to query node`)

      deploySuccess.value = `Deployed "${cmdName}" - query replica created on query node`
    } else {
      await deployService({
        app: selectedApp.value,
        name: baseName,
        config_yaml: yaml,
        admin_uid: form.value.admin_uid.trim() || 'admin',
        admin_key: form.value.admin_key.trim(),
        description: form.value.description.trim(),
        ...(activeTab.value === 'backup' ? { restore_path: restorePath.value.trim() } : {}),
      })

      deploySuccess.value = `Service "${baseName}" deployed successfully`
    }
  } catch (e) {
    deployError.value = e?.message || String(e)
  } finally {
    deploying.value = false
  }
}

async function onCreateApp() {
  if (!newAppName.value.trim()) return
  try {
    await createApp(newAppName.value.trim(), newAppDesc.value.trim())
    selectedApp.value = newAppName.value.trim()
    showNewApp.value = false
    newAppName.value = ''
    newAppDesc.value = ''
    emit('apps-changed')
  } catch (e) {
    deployError.value = e?.message || 'Failed to create app'
  }
}

function reset() {
  form.value = { name: '', description: '', admin_uid: 'admin', admin_key: DEFAULT_ADMIN_KEY }
  configYaml.value = ''
  restorePath.value = ''
  deployError.value = ''
  deploySuccess.value = ''
  deployLog.value = []
  deploying.value = false
}
</script>

<template>
  <div class="flex-1 flex flex-col bg-white text-slate-800 overflow-hidden">
    <div class="flex items-center gap-3 px-6 py-4 border-b border-slate-200">
      <button
        class="flex items-center gap-1 text-xs text-slate-400 hover:text-blue-600 transition-colors"
        @click="emit('navigate', { type: 'services' })"
      >
        <ChevronLeft :size="14" />
        Services
      </button>
      <h1 class="text-lg font-semibold flex items-center gap-2 text-slate-800">
        <Rocket :size="20" class="text-blue-500" />
        Deploy New Service
      </h1>
    </div>

    <div class="flex border-b border-slate-200 px-6">
      <button
        v-for="tab in tabs" :key="tab.key"
        class="flex items-center gap-2 px-4 py-2.5 text-xs font-medium border-b-2 transition-colors -mb-px"
        :class="activeTab === tab.key
          ? 'border-blue-500 text-blue-600'
          : 'border-transparent text-slate-400 hover:text-slate-600'"
        @click="activeTab = tab.key; deployError = ''"
      >
        <component :is="tab.icon" :size="14" />
        {{ tab.label }}
      </button>
    </div>

    <div class="flex-1 overflow-auto">
      <div class="max-w-2xl mx-auto px-6 py-6 space-y-6">

        <template v-if="deploySuccess">
          <div class="p-4 bg-green-50 border border-green-200 rounded-lg text-sm text-green-700">
            {{ deploySuccess }}
          </div>
          <div class="flex gap-3">
            <button class="px-4 py-2 text-xs bg-blue-600 hover:bg-blue-500 text-white rounded font-medium" @click="emit('navigate', { type: 'services' })">
              Go to Services
            </button>
            <button class="px-4 py-2 text-xs bg-slate-100 hover:bg-slate-200 text-slate-700 rounded font-medium" @click="reset">
              Deploy Another
            </button>
          </div>
        </template>

        <template v-else-if="deploying">
          <div class="flex items-center justify-center py-16">
            <div class="text-center">
              <div class="animate-spin w-8 h-8 border-2 border-blue-500 border-t-transparent rounded-full mx-auto mb-4" />
              <p class="text-sm text-slate-500">Deploying {{ form.name }}...</p>
              <div v-if="deployLog.length" class="mt-3 text-left max-w-sm mx-auto">
                <p v-for="(msg, i) in deployLog" :key="i" class="text-[11px] text-slate-400">{{ msg }}</p>
              </div>
            </div>
          </div>
        </template>

        <template v-else>
          <div v-if="deployError" class="p-3 bg-red-50 border border-red-200 rounded text-xs text-red-600">
            {{ deployError }}
          </div>

          <div class="space-y-3">
            <div>
              <label class="block text-xs font-medium text-slate-500 mb-1">App *</label>
              <div class="flex items-center gap-2">
                <select
                  v-model="selectedApp"
                  class="flex-1 bg-white border border-slate-300 rounded text-sm text-slate-800 px-3 py-2 focus:outline-none focus:border-blue-500"
                >
                  <option value="" disabled>Select an app...</option>
                  <option v-for="app in props.apps" :key="app.name" :value="app.name">{{ app.name }}</option>
                </select>
                <button
                  class="px-3 py-2 text-xs bg-slate-100 hover:bg-slate-200 text-slate-700 rounded font-medium whitespace-nowrap"
                  @click="showNewApp = !showNewApp"
                >
                  {{ showNewApp ? 'Cancel' : '+ New App' }}
                </button>
              </div>
            </div>

            <div v-if="showNewApp" class="p-3 bg-slate-50 border border-slate-200 rounded space-y-2">
              <div>
                <label class="block text-[10px] font-medium text-slate-500 mb-0.5">App Name</label>
                <input v-model="newAppName" type="text" class="w-full bg-white border border-slate-300 rounded text-sm text-slate-800 px-3 py-1.5 focus:outline-none focus:border-blue-500" placeholder="e.g. ecommerce" />
              </div>
              <div>
                <label class="block text-[10px] font-medium text-slate-500 mb-0.5">Description</label>
                <input v-model="newAppDesc" type="text" class="w-full bg-white border border-slate-300 rounded text-sm text-slate-800 px-3 py-1.5 focus:outline-none focus:border-blue-500" placeholder="Optional" />
              </div>
              <button
                class="px-3 py-1.5 text-xs bg-blue-600 hover:bg-blue-500 text-white rounded font-medium"
                @click="onCreateApp"
              >
                Create App
              </button>
            </div>
          </div>

          <div class="space-y-3">
            <div>
              <label class="block text-xs font-medium text-slate-500 mb-1">Service Name *</label>
              <input
                v-model="form.name" type="text"
                class="w-full bg-white border border-slate-300 rounded text-sm text-slate-800 px-3 py-2 focus:outline-none focus:border-blue-500"
                placeholder="e.g. orders"
              />
              <p v-if="replicaEnabled && form.name" class="text-[10px] text-blue-600 mt-1">
                Replica enabled - will deploy <strong>{{ form.name }}.db.command</strong> and <strong>{{ form.name }}.db.query</strong>
              </p>
            </div>
            <div>
              <label class="block text-xs font-medium text-slate-500 mb-1">Description</label>
              <input
                v-model="form.description" type="text"
                class="w-full bg-white border border-slate-300 rounded text-sm text-slate-800 px-3 py-2 focus:outline-none focus:border-blue-500"
                placeholder="Optional description"
              />
            </div>
          </div>

          <div>
            <label class="block text-xs font-medium text-slate-500 mb-1">Admin UID</label>
            <input v-model="form.admin_uid" type="text" class="w-full bg-white border border-slate-300 rounded text-xs text-slate-800 px-3 py-2 focus:outline-none focus:border-blue-500" placeholder="admin" />
          </div>

          <template v-if="activeTab === 'manifest'">
            <div>
              <label class="block text-xs font-medium text-slate-500 mb-2">Config YAML *</label>
              <div class="flex items-center gap-3">
                <label class="px-3 py-2 text-xs bg-slate-100 text-slate-600 rounded hover:bg-slate-200 cursor-pointer transition-colors border border-slate-300">
                  <Upload :size="12" class="inline mr-1" />
                  Upload YAML
                  <input type="file" accept=".yaml,.yml" class="hidden" @change="onFileUpload" />
                </label>
                <span v-if="configYaml" class="text-xs text-green-600 flex items-center gap-1">
                  Loaded
                  <span v-if="replicaEnabled" class="text-[10px] px-1.5 py-0.5 bg-blue-100 text-blue-700 rounded font-medium">replica</span>
                  <span v-else class="text-[10px] px-1.5 py-0.5 bg-slate-100 text-slate-500 rounded font-medium">standalone</span>
                </span>
                <span v-else class="text-[10px] text-slate-400">Upload a config.yaml file</span>
              </div>
            </div>

          </template>

          <template v-if="activeTab === 'backup'">
            <div>
              <label class="block text-xs font-medium text-slate-500 mb-1">Backup Path *</label>
              <input
                v-model="restorePath" type="text"
                class="w-full bg-white border border-slate-300 rounded text-xs text-slate-800 px-3 py-2 font-mono focus:outline-none focus:border-blue-500"
                placeholder="/path/to/backup"
              />
              <p class="text-[10px] text-slate-400 mt-1">Path to the backup snapshot directory on the server</p>
            </div>
          </template>

          <div class="flex justify-end gap-3 pt-2 border-t border-slate-200">
            <button
              class="px-4 py-2 text-xs text-slate-500 hover:text-slate-700 hover:bg-slate-100 rounded transition-colors"
              @click="emit('navigate', { type: 'services' })"
            >
              Cancel
            </button>
            <button
              class="px-4 py-2 text-xs bg-blue-600 hover:bg-blue-500 text-white rounded font-medium flex items-center gap-2 transition-colors disabled:opacity-50"
              :disabled="deploying"
              @click="onDeploy"
            >
              <Rocket :size="14" />
              {{ activeTab === 'backup' ? 'Deploy + Restore' : 'Deploy' }}
            </button>
          </div>
        </template>
      </div>
    </div>
  </div>
</template>
