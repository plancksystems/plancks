<script setup>
import { ref, computed } from 'vue'
import { importManifest } from '../api'
import Modal from './Modal.vue'
import { Upload, Calendar, Play } from 'lucide-vue-next'

const props = defineProps({
  serviceName: String,
  storeName: String,
})
const emit = defineEmits(['close', 'done'])

const manifest = ref(props.storeName ? `store: ${props.storeName}\nformat: json\noutput_dir: /tmp/export\n` : '')
const mode = ref('now')
const scheduleName = ref('')
const cronExpr = ref('')
const description = ref('')
const loading = ref(false)
const error = ref(null)
const result = ref(null)

const cronPresets = [
  { label: 'Daily 2am', expr: '0 2 * * *' },
  { label: 'Daily 4am', expr: '0 4 * * *' },
  { label: 'Weekly Sun 3am', expr: '0 3 * * 0' },
  { label: 'Hourly', expr: '0 * * * *' },
]

const preview = computed(() => {
  const lines = manifest.value.split('\n')
  const fields = {}
  for (const line of lines) {
    const m = line.match(/^(\w+)\s*:\s*(.+)/)
    if (m) fields[m[1]] = m[2].trim()
  }
  return fields
})

function onFileUpload(e) {
  const file = e.target.files[0]
  if (!file) return
  const reader = new FileReader()
  reader.onload = () => { manifest.value = reader.result }
  reader.readAsText(file)
}

async function onSubmit() {
  if (!manifest.value.trim()) { error.value = 'Manifest is required'; return }
  if (mode.value === 'schedule') {
    if (!scheduleName.value.trim()) { error.value = 'Schedule name is required'; return }
    if (!cronExpr.value.trim()) { error.value = 'Cron expression is required'; return }
  }
  error.value = null
  loading.value = true
  const start = Date.now()
  try {
    const opts = { service: props.serviceName }
    if (mode.value === 'schedule') {
      opts.cron_expr = cronExpr.value
      opts.name = scheduleName.value
      if (description.value) opts.description = description.value
    }
    const data = await importManifest(manifest.value, opts)
    const elapsed = ((Date.now() - start) / 1000).toFixed(1)
    if (data.scheduled) {
      result.value = `Schedule created (${elapsed}s)`
    } else {
      result.value = `${data.message || 'Import complete'} (${elapsed}s)`
    }
    emit('done')
  } catch (e) {
    const elapsed = ((Date.now() - start) / 1000).toFixed(1)
    error.value = `${e.message} (${elapsed}s)`
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <Modal title="Import" @close="emit('close')">
    <div class="space-y-3">
      <div>
        <div class="flex items-center justify-between mb-1">
          <label class="text-xs font-medium text-slate-600">Manifest (YAML)</label>
          <label class="text-[10px] text-blue-600 hover:text-blue-500 cursor-pointer flex items-center gap-1">
            <Upload :size="10" /> Upload file
            <input type="file" accept=".yaml,.yml,.txt" class="hidden" @change="onFileUpload" />
          </label>
        </div>
        <textarea
          v-model="manifest"
          rows="8"
          class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded font-mono focus:outline-none focus:ring-1 focus:ring-blue-500 resize-y"
          placeholder="store: my_store&#10;format: csv&#10;output_dir: /tmp/data&#10;entities:&#10;  - name: orders&#10;    file: orders.csv&#10;    fields:&#10;      - name: id&#10;        type: int64"
        />
      </div>

      <div v-if="preview.store || preview.format" class="p-2 bg-slate-50 rounded border border-slate-200 text-xs space-y-0.5">
        <div v-if="preview.store" class="flex gap-2"><span class="text-slate-400 w-16">Store:</span><span class="font-mono text-slate-700">{{ preview.store }}</span></div>
        <div v-if="preview.format" class="flex gap-2"><span class="text-slate-400 w-16">Format:</span><span class="text-slate-700">{{ preview.format }}</span></div>
        <div v-if="preview.output_dir" class="flex gap-2"><span class="text-slate-400 w-16">Source:</span><span class="font-mono text-slate-700">{{ preview.output_dir }}</span></div>
      </div>

      <div class="flex gap-2">
        <button
          class="flex-1 px-3 py-1.5 text-xs rounded border flex items-center justify-center gap-1.5 transition-colors"
          :class="mode === 'now' ? 'bg-blue-50 border-blue-300 text-blue-700' : 'border-slate-300 text-slate-500 hover:bg-slate-50'"
          @click="mode = 'now'"
        ><Play :size="12" /> Run Now</button>
        <button
          class="flex-1 px-3 py-1.5 text-xs rounded border flex items-center justify-center gap-1.5 transition-colors"
          :class="mode === 'schedule' ? 'bg-violet-50 border-violet-300 text-violet-700' : 'border-slate-300 text-slate-500 hover:bg-slate-50'"
          @click="mode = 'schedule'"
        ><Calendar :size="12" /> Schedule</button>
      </div>

      <template v-if="mode === 'schedule'">
        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">Schedule Name</label>
          <input v-model="scheduleName" type="text" class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500" placeholder="nightly-data-import" />
        </div>
        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">Cron Expression</label>
          <input v-model="cronExpr" type="text" class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded font-mono focus:outline-none focus:ring-1 focus:ring-blue-500" placeholder="0 2 * * *" />
          <div class="flex gap-1.5 mt-1">
            <button v-for="p in cronPresets" :key="p.expr" class="px-1.5 py-0.5 text-[10px] bg-slate-100 hover:bg-slate-200 rounded text-slate-500" @click="cronExpr = p.expr">{{ p.label }}</button>
          </div>
        </div>
        <div>
          <label class="block text-xs font-medium text-slate-600 mb-1">Description</label>
          <input v-model="description" type="text" class="w-full px-2 py-1.5 text-xs border border-slate-300 rounded focus:outline-none focus:ring-1 focus:ring-blue-500" placeholder="Optional description" />
        </div>
      </template>

      <div v-if="error" class="p-2 bg-red-50 border border-red-200 rounded text-xs text-red-600">{{ error }}</div>
      <div v-if="result" class="p-2 bg-green-50 border border-green-200 rounded text-xs text-green-700">{{ result }}</div>
    </div>
    <template #footer>
      <button class="px-3 py-1.5 text-xs text-slate-600 hover:bg-slate-100 rounded" @click="emit('close')">Cancel</button>
      <button class="px-3 py-1.5 text-xs bg-blue-600 text-white rounded hover:bg-blue-700 disabled:opacity-50" :disabled="loading" @click="onSubmit">
        {{ loading ? 'Working...' : mode === 'schedule' ? 'Create Schedule' : 'Import' }}
      </button>
    </template>
  </Modal>
</template>
