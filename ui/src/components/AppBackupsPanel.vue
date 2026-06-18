<script setup>
import { ref, onMounted, watch } from 'vue'
import { fetchAppBackups, createAppBackup, deleteAppBackup } from '../api'
import { HardDrive, Plus, Trash2, RefreshCw, AlertTriangle, Terminal, Copy, Check } from 'lucide-vue-next'

const props = defineProps({
  appName: { type: String, required: true },
})

const backups = ref([])
const loading = ref(false)
const error = ref(null)

const showCreateForm = ref(false)
const createPath = ref('')
const creating = ref(false)

const deleteTarget = ref(null)

const restoreTip = ref(null)
const copied = ref(false)

async function loadBackups() {
  loading.value = true
  error.value = null
  try {
    backups.value = await fetchAppBackups(props.appName)
  } catch (e) {
    error.value = e.message
    backups.value = []
  } finally {
    loading.value = false
  }
}

async function onCreate() {
  creating.value = true
  error.value = null
  try {
    await createAppBackup(props.appName, createPath.value.trim())
    showCreateForm.value = false
    createPath.value = ''
    await loadBackups()
  } catch (e) {
    error.value = e.message
  } finally {
    creating.value = false
  }
}

async function onDelete(backup) {
  error.value = null
  try {
    await deleteAppBackup(backup.backup_path || backup.path)
    deleteTarget.value = null
    await loadBackups()
  } catch (e) {
    error.value = e.message
  }
}

function restoreCmd(backup) {
  const p = backup.backup_path || backup.path
  return `sudo planctl restore --app ${props.appName} --backup ${p} --profile <profile>`
}

async function copyCmd(cmd) {
  try {
    await navigator.clipboard.writeText(cmd)
    copied.value = true
    setTimeout(() => { copied.value = false }, 1500)
  } catch {  }
}

function formatSize(bytes) {
  if (!bytes) return '-'
  if (bytes < 1024) return bytes + ' B'
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB'
  if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB'
  return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB'
}

function formatDate(ts) {
  if (!ts) return '-'
  return new Date(ts).toLocaleString()
}

onMounted(loadBackups)
watch(() => props.appName, loadBackups)
</script>

<template>
  <div class="flex-1 flex flex-col bg-white min-w-0 overflow-hidden">
    <div class="bg-slate-100 border-b border-slate-200 flex items-center px-4 py-2">
      <HardDrive :size="16" class="text-slate-500 mr-2" />
      <span class="text-sm font-medium text-slate-700">Backups</span>
      <span class="text-xs text-slate-400 ml-2">{{ appName }}</span>
      <div class="ml-auto flex gap-2">
        <button
          class="px-2 py-1 text-xs text-slate-600 hover:bg-slate-200 rounded flex items-center gap-1"
          @click="loadBackups"
          :disabled="loading"
        >
          <RefreshCw :size="12" :class="{ 'animate-spin': loading }" /> Refresh
        </button>
        <button
          class="px-2.5 py-1 text-xs bg-blue-600 text-white rounded hover:bg-blue-700 flex items-center gap-1"
          @click="showCreateForm = true"
        >
          <Plus :size="12" /> Create Backup
        </button>
      </div>
    </div>

    <div v-if="error" class="px-4 py-2 bg-red-50 border-b border-red-200 text-xs text-red-600 flex items-center gap-2">
      <AlertTriangle :size="14" />
      {{ error }}
      <button class="ml-auto text-red-400 hover:text-red-600" @click="error = null">&times;</button>
    </div>

    <div class="flex-1 overflow-y-auto p-4">
      <div v-if="showCreateForm" class="mb-4 p-3 bg-slate-50 border border-slate-200 rounded">
        <div class="text-xs font-medium text-slate-600 mb-2">Create Backup for '{{ appName }}'</div>
        <div class="flex gap-2">
          <input
            v-model="createPath"
            type="text"
            class="flex-1 px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500 font-mono"
            placeholder="output dir (optional; defaults to ~/.planck/backups/<app>)"
            @keyup.enter="onCreate"
            autofocus
          />
          <button
            class="px-3 py-1.5 text-xs bg-blue-600 text-white rounded hover:bg-blue-700 disabled:opacity-50"
            :disabled="creating"
            @click="onCreate"
          >
            {{ creating ? 'Creating...' : 'Create' }}
          </button>
          <button class="px-2 py-1.5 text-xs text-slate-500 hover:bg-slate-200 rounded" @click="showCreateForm = false">Cancel</button>
        </div>
        <div class="mt-2 text-[10px] text-slate-400">
          Files land at <code class="bg-white px-1 py-0.5 rounded">&lt;dir&gt;/{{ appName }}/backup_&lt;ts&gt;.tar.gz</code>.
        </div>
      </div>

      <div v-if="backups.length > 0" class="space-y-2">
        <div
          v-for="(backup, idx) in backups"
          :key="idx"
          class="p-3 bg-white border border-slate-200 rounded hover:border-slate-300 transition"
        >
          <div class="flex items-center justify-between">
            <div class="min-w-0 flex-1 mr-3">
              <div class="text-xs font-medium text-slate-700 font-mono truncate">{{ backup.backup_path || backup.path }}</div>
              <div class="text-[10px] text-slate-400 mt-0.5 flex gap-3">
                <span v-if="backup.created_at_ms">{{ formatDate(backup.created_at_ms) }}</span>
                <span v-else-if="backup.timestamp">{{ formatDate(backup.timestamp) }}</span>
                <span v-if="backup.size_bytes">{{ formatSize(backup.size_bytes) }}</span>
                <span v-if="backup.kind" class="px-1.5 py-0.5 bg-slate-100 rounded">{{ backup.kind }}</span>
                <span v-if="backup.format" class="px-1.5 py-0.5 bg-slate-100 rounded">{{ backup.format }}</span>
              </div>
            </div>
            <div class="flex gap-1 flex-shrink-0">
              <button
                class="px-2 py-1 text-[10px] text-blue-600 hover:bg-blue-50 rounded flex items-center gap-1"
                @click="restoreTip = backup"
                title="Show planctl restore command"
              >
                <Terminal :size="11" /> Restore
              </button>
              <button
                class="px-2 py-1 text-[10px] text-red-500 hover:bg-red-50 rounded flex items-center gap-1"
                @click="deleteTarget = backup"
              >
                <Trash2 :size="11" /> Delete
              </button>
            </div>
          </div>
        </div>
      </div>

      <div v-else-if="!loading" class="text-center py-12">
        <HardDrive :size="32" class="mx-auto text-slate-300 mb-2" />
        <p class="text-sm text-slate-400">No backups found for '{{ appName }}'</p>
        <p class="text-xs text-slate-400 mt-1">Create one above, or set up a schedule.</p>
      </div>
    </div>

    <div v-if="restoreTip" class="fixed inset-0 bg-black/30 flex items-center justify-center z-50" @click.self="restoreTip = null">
      <div class="bg-white rounded-lg shadow-xl p-4 w-[520px]">
        <div class="flex items-center gap-2 text-blue-600 mb-3">
          <Terminal :size="18" />
          <span class="text-sm font-medium">Restore from CLI</span>
        </div>
        <p class="text-xs text-slate-600 mb-3">
          Restore is a CLI-only operation (it touches launchd plists and
          must run with <code>sudo</code>). Copy and run:
        </p>
        <div class="relative">
          <pre class="text-[11px] text-slate-700 font-mono bg-slate-50 border border-slate-200 p-2 rounded overflow-x-auto whitespace-pre-wrap break-all">{{ restoreCmd(restoreTip) }}</pre>
          <button
            class="absolute top-1.5 right-1.5 px-1.5 py-0.5 text-[10px] text-slate-500 hover:bg-slate-200 rounded flex items-center gap-1"
            @click="copyCmd(restoreCmd(restoreTip))"
          >
            <Check v-if="copied" :size="11" class="text-green-600" />
            <Copy v-else :size="11" />
            {{ copied ? 'Copied' : 'Copy' }}
          </button>
        </div>
        <div class="flex justify-end mt-3">
          <button class="px-3 py-1.5 text-xs text-slate-600 hover:bg-slate-100 rounded" @click="restoreTip = null">Close</button>
        </div>
      </div>
    </div>

    <div v-if="deleteTarget" class="fixed inset-0 bg-black/30 flex items-center justify-center z-50" @click.self="deleteTarget = null">
      <div class="bg-white rounded-lg shadow-xl p-4 w-96">
        <div class="flex items-center gap-2 text-red-600 mb-3">
          <Trash2 :size="18" />
          <span class="text-sm font-medium">Delete Backup</span>
        </div>
        <p class="text-xs text-slate-600 mb-2">
          Permanently delete this backup file and its sysdb record?
        </p>
        <div class="text-xs text-slate-500 font-mono bg-slate-50 p-2 rounded mb-3 break-all">
          {{ deleteTarget.backup_path || deleteTarget.path }}
        </div>
        <div class="flex justify-end gap-2">
          <button class="px-3 py-1.5 text-xs text-slate-600 hover:bg-slate-100 rounded" @click="deleteTarget = null">Cancel</button>
          <button
            class="px-3 py-1.5 text-xs bg-red-600 text-white rounded hover:bg-red-700"
            @click="onDelete(deleteTarget)"
          >
            Delete
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
