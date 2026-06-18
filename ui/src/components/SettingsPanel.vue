<script setup>
import { ref, onMounted } from 'vue'
import { Settings, Info, Server, Shield, Palette, Globe, Upload, Trash2, RefreshCw } from 'lucide-vue-next'
import { fetchShellApps, registerShellApp, updateShellApp, deleteShellApp } from '../api'

const props = defineProps({
  role: { type: String, default: 'standalone' },
  version: { type: String, default: '' },
})

const activeSection = ref('general')

const sections = [
  { key: 'general', label: 'General', icon: Server },
  { key: 'defaults', label: 'Defaults', icon: Settings },
  { key: 'shells', label: 'Shell Apps', icon: Globe },
  { key: 'appearance', label: 'Appearance', icon: Palette },
  { key: 'about', label: 'About', icon: Info },
]

const theme = ref(localStorage.getItem('planck-theme') || 'light')

function setTheme(t) {
  theme.value = t
  localStorage.setItem('planck-theme', t)
}

const shellApps = ref([])
const shellsLoading = ref(false)
const shellsError = ref('')
const showRegister = ref(false)
const registerForm = ref({ name: '', description: '' })
const registerFile = ref(null)
const registerError = ref('')
const registering = ref(false)

async function loadShells() {
  shellsLoading.value = true
  shellsError.value = ''
  try {
    const data = await fetchShellApps()
    shellApps.value = data.shells || []
  } catch (e) {
    shellsError.value = e.message
  } finally {
    shellsLoading.value = false
  }
}

function onRegisterFile(e) {
  registerFile.value = e.target.files?.[0] || null
}

async function onRegister() {
  registerError.value = ''
  if (!registerForm.value.name.trim()) { registerError.value = 'Name is required'; return }
  if (!registerFile.value) { registerError.value = 'index.html file is required'; return }
  registering.value = true
  try {
    await registerShellApp(registerForm.value.name.trim(), registerForm.value.description.trim(), registerFile.value)
    showRegister.value = false
    registerForm.value = { name: '', description: '' }
    registerFile.value = null
    await loadShells()
  } catch (e) {
    registerError.value = e.message
  } finally {
    registering.value = false
  }
}

async function onUpdateShell(name) {
  const input = document.createElement('input')
  input.type = 'file'
  input.accept = '.html,.htm'
  input.onchange = async () => {
    const file = input.files?.[0]
    if (!file) return
    try {
      await updateShellApp(name, file)
      await loadShells()
    } catch (e) {
      shellsError.value = e.message
    }
  }
  input.click()
}

async function onDeleteShell(name) {
  if (!confirm(`Delete shell app "${name}"?`)) return
  try {
    await deleteShellApp(name)
    await loadShells()
  } catch (e) {
    shellsError.value = e.message
  }
}

onMounted(() => {
  loadShells()
})
</script>

<template>
  <div class="flex-1 flex bg-white text-slate-800 min-w-0 overflow-hidden">
    <div class="w-48 bg-slate-50 border-r border-slate-200 py-4 shrink-0">
      <div class="px-4 mb-4">
        <h2 class="text-sm font-semibold flex items-center gap-2 text-slate-700">
          <Settings :size="16" class="text-slate-400" />
          Settings
        </h2>
      </div>
      <nav class="space-y-0.5 px-2">
        <button
          v-for="sec in sections" :key="sec.key"
          class="w-full text-left px-3 py-2 text-xs rounded flex items-center gap-2 transition-colors"
          :class="activeSection === sec.key ? 'bg-blue-50 text-blue-700' : 'text-slate-500 hover:text-slate-700 hover:bg-slate-100'"
          @click="activeSection = sec.key"
        >
          <component :is="sec.icon" :size="14" />
          {{ sec.label }}
        </button>
      </nav>
    </div>

    <div class="flex-1 overflow-auto p-8">
      <div class="max-w-xl">

        <template v-if="activeSection === 'general'">
          <h3 class="text-sm font-semibold mb-4 text-slate-800">General</h3>
          <div class="space-y-3">
            <div class="flex items-center justify-between p-3 bg-slate-50 rounded border border-slate-200">
              <div>
                <div class="text-xs font-medium text-slate-700">Node Role</div>
                <div class="text-[10px] text-slate-400 mt-0.5">Determines whether this node is primary or replica</div>
              </div>
              <span class="text-xs font-medium px-2 py-0.5 rounded"
                :class="{
                  'bg-blue-100 text-blue-700': role === 'command',
                  'bg-amber-100 text-amber-700': role === 'query',
                  'bg-slate-200 text-slate-600': role === 'standalone',
                }"
              >{{ role }}</span>
            </div>

            <div class="flex items-center justify-between p-3 bg-slate-50 rounded border border-slate-200">
              <div>
                <div class="text-xs font-medium text-slate-700">Workbench Port</div>
                <div class="text-[10px] text-slate-400 mt-0.5">HTTP server port for the workbench UI</div>
              </div>
              <span class="text-xs font-mono text-slate-500">2369</span>
            </div>

            <div class="flex items-center justify-between p-3 bg-slate-50 rounded border border-slate-200">
              <div>
                <div class="text-xs font-medium text-slate-700">Bind Address</div>
                <div class="text-[10px] text-slate-400 mt-0.5">Network interface the server listens on</div>
              </div>
              <span class="text-xs font-mono text-slate-500">127.0.0.1</span>
            </div>

            <div class="flex items-center justify-between p-3 bg-slate-50 rounded border border-slate-200">
              <div>
                <div class="text-xs font-medium text-slate-700">Scheduler Interval</div>
                <div class="text-[10px] text-slate-400 mt-0.5">Background scheduler check interval</div>
              </div>
              <span class="text-xs font-mono text-slate-500">60s</span>
            </div>
          </div>

          <p class="text-[10px] text-slate-400 mt-4">
            Settings are configured via <span class="font-mono text-slate-500">config.yaml</span> in the workbench data directory.
            Changes require a workbench restart.
          </p>
        </template>

        <template v-else-if="activeSection === 'defaults'">
          <h3 class="text-sm font-semibold mb-4 text-slate-800">Default Service Config</h3>
          <p class="text-xs text-slate-400 mb-4">Default values used when deploying new services.</p>
          <div class="space-y-3">
            <div class="flex items-center justify-between p-3 bg-slate-50 rounded border border-slate-200">
              <div>
                <div class="text-xs font-medium text-slate-700">Memtable Budget</div>
                <div class="text-[10px] text-slate-400 mt-0.5">Memory allocated for write buffer before flush</div>
              </div>
              <span class="text-xs font-mono text-slate-500">16 MB</span>
            </div>

            <div class="flex items-center justify-between p-3 bg-slate-50 rounded border border-slate-200">
              <div>
                <div class="text-xs font-medium text-slate-700">WAL Budget</div>
                <div class="text-[10px] text-slate-400 mt-0.5">Write-ahead log size before rotation</div>
              </div>
              <span class="text-xs font-mono text-slate-500">16 MB</span>
            </div>

            <div class="flex items-center justify-between p-3 bg-slate-50 rounded border border-slate-200">
              <div>
                <div class="text-xs font-medium text-slate-700">Durability</div>
                <div class="text-[10px] text-slate-400 mt-0.5">fsync policy for data safety</div>
              </div>
              <span class="text-xs font-mono text-slate-500">full</span>
            </div>
          </div>

          <p class="text-[10px] text-slate-400 mt-4">
            These can be overridden per-service in the deploy panel's Advanced section.
          </p>
        </template>

        <template v-else-if="activeSection === 'shells'">
          <div class="flex items-center justify-between mb-4">
            <h3 class="text-sm font-semibold text-slate-800">Shell Apps</h3>
            <button
              class="px-3 py-1.5 text-xs bg-blue-600 hover:bg-blue-500 text-white rounded font-medium transition-colors"
              @click="showRegister = true; registerError = ''"
            >
              Register App
            </button>
          </div>

          <p class="text-xs text-slate-400 mb-4">Static shell apps served as micro-frontend entry points. Each app is an index.html that loads HTML fragments from deployed services via HTMX.</p>

          <div v-if="shellsError" class="p-3 bg-red-50 border border-red-200 rounded text-xs text-red-600 mb-4">
            {{ shellsError }}
          </div>

          <div v-if="showRegister" class="p-4 bg-slate-50 border border-slate-200 rounded-lg mb-4 space-y-3">
            <div class="text-xs font-medium text-slate-700">Register New Shell App</div>
            <div v-if="registerError" class="p-2 bg-red-50 border border-red-200 rounded text-xs text-red-600">{{ registerError }}</div>
            <div>
              <label class="block text-[10px] text-slate-500 mb-1">Name *</label>
              <input v-model="registerForm.name" type="text" class="w-full bg-white border border-slate-300 rounded text-xs text-slate-800 px-3 py-1.5 focus:outline-none focus:border-blue-500" placeholder="e.g. sales" />
            </div>
            <div>
              <label class="block text-[10px] text-slate-500 mb-1">Description</label>
              <input v-model="registerForm.description" type="text" class="w-full bg-white border border-slate-300 rounded text-xs text-slate-800 px-3 py-1.5 focus:outline-none focus:border-blue-500" placeholder="Sales dashboard" />
            </div>
            <div>
              <label class="block text-[10px] text-slate-500 mb-1">index.html *</label>
              <label class="inline-flex items-center gap-1 px-3 py-1.5 text-xs bg-white text-slate-600 rounded hover:bg-slate-100 cursor-pointer border border-slate-300">
                <Upload :size="12" />
                Upload
                <input type="file" accept=".html,.htm" class="hidden" @change="onRegisterFile" />
              </label>
              <span v-if="registerFile" class="ml-2 text-xs text-green-600">{{ registerFile.name }}</span>
            </div>
            <div class="flex gap-2 pt-1">
              <button class="px-3 py-1.5 text-xs bg-blue-600 hover:bg-blue-500 text-white rounded font-medium disabled:opacity-50" :disabled="registering" @click="onRegister">
                {{ registering ? 'Registering...' : 'Register' }}
              </button>
              <button class="px-3 py-1.5 text-xs text-slate-500 hover:text-slate-700" @click="showRegister = false">Cancel</button>
            </div>
          </div>

          <div v-if="shellsLoading" class="text-xs text-slate-400 py-4">Loading...</div>
          <div v-else-if="shellApps.length === 0" class="text-xs text-slate-400 py-4">No shell apps registered.</div>
          <div v-else class="space-y-2">
            <div v-for="app in shellApps" :key="app.name" class="flex items-center justify-between p-3 bg-slate-50 rounded border border-slate-200">
              <div class="min-w-0">
                <div class="text-xs font-medium text-slate-700">{{ app.name }}</div>
                <div v-if="app.description" class="text-[10px] text-slate-400 mt-0.5">{{ app.description }}</div>
                <div class="text-[10px] text-slate-400 mt-0.5 font-mono">/apps/{{ app.path }}/</div>
              </div>
              <div class="flex items-center gap-1 shrink-0">
                <button
                  class="p-1.5 text-slate-400 hover:text-blue-600 rounded hover:bg-blue-50 transition-colors"
                  title="Update index.html"
                  @click="onUpdateShell(app.name)"
                >
                  <RefreshCw :size="13" />
                </button>
                <button
                  class="p-1.5 text-slate-400 hover:text-red-600 rounded hover:bg-red-50 transition-colors"
                  title="Delete"
                  @click="onDeleteShell(app.name)"
                >
                  <Trash2 :size="13" />
                </button>
              </div>
            </div>
          </div>
        </template>

        <template v-else-if="activeSection === 'appearance'">
          <h3 class="text-sm font-semibold mb-4 text-slate-800">Appearance</h3>
          <div class="space-y-3">
            <div class="p-3 bg-slate-50 rounded border border-slate-200">
              <div class="text-xs font-medium text-slate-700 mb-3">Theme</div>
              <div class="flex gap-2">
                <button
                  class="px-4 py-2 text-xs rounded border transition-colors"
                  :class="theme === 'dark' ? 'bg-slate-100 border-slate-300 text-slate-600' : 'bg-white border-slate-200 text-slate-400 hover:border-slate-300'"
                  @click="setTheme('dark')"
                >
                  Dark
                </button>
                <button
                  class="px-4 py-2 text-xs rounded border transition-colors"
                  :class="theme === 'light' ? 'bg-blue-50 border-blue-500 text-blue-700' : 'bg-white border-slate-200 text-slate-400 hover:border-slate-300'"
                  @click="setTheme('light')"
                >
                  Light
                </button>
              </div>
            </div>
          </div>
        </template>

        <template v-else-if="activeSection === 'about'">
          <h3 class="text-sm font-semibold mb-4 text-slate-800">About</h3>
          <div class="space-y-3">
            <div class="flex items-center justify-between p-3 bg-slate-50 rounded border border-slate-200">
              <div>
                <div class="text-xs font-medium text-slate-700">Version</div>
                <div class="text-[10px] text-slate-400 mt-0.5">Planck Workbench</div>
              </div>
              <span class="text-xs font-mono text-slate-600">{{ version || 'unknown' }}</span>
            </div>

            <div class="flex items-center justify-between p-3 bg-slate-50 rounded border border-slate-200">
              <div>
                <div class="text-xs font-medium text-slate-700">Platform</div>
                <div class="text-[10px] text-slate-400 mt-0.5">Server operating system</div>
              </div>
              <span class="text-xs font-mono text-slate-500">{{ navigator.platform || 'unknown' }}</span>
            </div>

            <div class="flex items-center justify-between p-3 bg-slate-50 rounded border border-slate-200">
              <div>
                <div class="text-xs font-medium text-slate-700">System DB</div>
                <div class="text-[10px] text-slate-400 mt-0.5">Internal storage for workbench state</div>
              </div>
              <span class="text-xs font-mono text-green-600">Connected</span>
            </div>

            <div class="p-3 bg-slate-50 rounded border border-slate-200">
              <div class="text-xs font-medium text-slate-700 mb-2">Data Paths</div>
              <div class="space-y-1 text-[10px] font-mono text-slate-400">
                <div>Config: <span class="text-slate-500">~/.planck/wb/config.yaml</span></div>
                <div>Services: <span class="text-slate-500">~/.planck/wb/services/</span></div>
                <div>Backups: <span class="text-slate-500">~/.planck/backups/</span></div>
                <div>Binary: <span class="text-slate-500">~/.planck/bin/planck</span></div>
              </div>
            </div>
          </div>
        </template>
      </div>
    </div>
  </div>
</template>
