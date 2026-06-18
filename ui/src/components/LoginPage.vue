<script setup>
import { ref } from 'vue'
import { connectSystemDb } from '../api'

const emit = defineEmits(['connected'])

const key = ref('')
const uid = ref('admin')
const error = ref('')
const loading = ref(false)
const newKey = ref(null)

async function onSubmit() {
  if (!key.value.trim()) {
    error.value = 'Admin key is required'
    return
  }
  error.value = ''
  loading.value = true
  try {
    const result = await connectSystemDb(key.value.trim(), uid.value.trim() || 'admin')
    if (result.new_key) {
      newKey.value = result.new_key
    } else {
      emit('connected')
    }
  } catch (e) {
    error.value = e.message
  } finally {
    loading.value = false
  }
}

function onCopied() {
  navigator.clipboard.writeText(newKey.value)
}

function onContinue() {
  emit('connected')
}
</script>

<template>
  <div class="min-h-screen bg-slate-50 flex items-center justify-center">
    <div class="w-full max-w-sm">
      <div class="text-center mb-8">
        <h1 class="text-2xl font-bold text-slate-800 tracking-tight">Planck</h1>
        <p class="text-slate-400 text-sm mt-1">Workbench</p>
      </div>

      <div v-if="newKey" class="bg-white rounded-lg border border-slate-200 p-6 shadow-sm">
        <h2 class="text-sm font-medium text-amber-600 mb-3">Admin Key Regenerated</h2>
        <p class="text-xs text-slate-600 mb-3">
          The default admin key has been replaced. Save this new key - it will not be shown again.
        </p>

        <div class="bg-slate-50 border border-slate-200 rounded p-3 mb-4">
          <code class="text-xs text-green-700 break-all select-all">{{ newKey }}</code>
        </div>

        <div class="flex gap-2">
          <button
            class="flex-1 py-2 px-4 bg-slate-100 hover:bg-slate-200 text-slate-700 text-sm rounded transition-colors"
            @click="onCopied"
          >
            Copy to Clipboard
          </button>
          <button
            class="flex-1 py-2 px-4 bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium rounded transition-colors"
            @click="onContinue"
          >
            Continue
          </button>
        </div>

        <p class="text-[10px] text-slate-400 mt-3 text-center">
          Credentials saved to disk for auto-reconnect on restart.
        </p>
      </div>

      <div v-else class="bg-white rounded-lg border border-slate-200 p-6 shadow-sm">
        <h2 class="text-sm font-medium text-slate-600 mb-4">Connect to System Database</h2>

        <form @submit.prevent="onSubmit" class="space-y-4">
          <div>
            <label class="block text-xs text-slate-500 mb-1">Admin User</label>
            <input
              v-model="uid"
              type="text"
              class="w-full px-3 py-2 bg-white border border-slate-300 rounded text-sm text-slate-800 placeholder-slate-400 focus:outline-none focus:border-blue-500"
              placeholder="admin"
            />
          </div>

          <div>
            <label class="block text-xs text-slate-500 mb-1">Admin Key</label>
            <input
              v-model="key"
              type="password"
              class="w-full px-3 py-2 bg-white border border-slate-300 rounded text-sm text-slate-800 placeholder-slate-400 focus:outline-none focus:border-blue-500"
              placeholder="Enter system DB admin key"
              autofocus
            />
          </div>

          <div v-if="error" class="text-red-500 text-xs">{{ error }}</div>

          <button
            type="submit"
            :disabled="loading"
            class="w-full py-2 px-4 bg-blue-600 hover:bg-blue-700 disabled:opacity-50 text-white text-sm font-medium rounded transition-colors"
          >
            {{ loading ? 'Connecting...' : 'Connect' }}
          </button>
        </form>

        <p class="text-xs text-slate-400 mt-4 text-center">
          Default key on first install:<br>
          <code class="text-slate-500 text-[10px] break-all">UGxhbmNrX0RlZmF1bHRfQWRtaW5fS2V5XzAwMTA=</code>
        </p>
      </div>
    </div>
  </div>
</template>
