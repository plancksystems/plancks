<script setup>
import { ref, watch } from 'vue'

const props = defineProps({
  service: { type: String, default: null },
  file: { type: String, default: null },
})

const logContent = ref('')
const totalLines = ref(0)
const searchQuery = ref('')
const loading = ref(false)
const offset = ref(0)
const pageSize = 1000

const logLines = ref([])

watch(logContent, (content) => {
  if (!content) { logLines.value = []; return }
  logLines.value = content.split('\n').filter(l => l.length > 0).map(l => {
    const tab = l.indexOf('\t')
    if (tab > 0) {
      return { num: l.substring(0, tab), text: l.substring(tab + 1) }
    }
    return { num: '', text: l }
  })
})

watch(() => [props.service, props.file], () => {
  offset.value = 0
  searchQuery.value = ''
  logContent.value = ''
  totalLines.value = 0
  if (props.service && props.file) {
    loadFileContent()
  }
}, { immediate: true })

async function loadFileContent() {
  if (!props.service || !props.file) return
  loading.value = true
  try {
    let url = `/api/logs?service=${encodeURIComponent(props.service)}&file=${encodeURIComponent(props.file)}&offset=${offset.value}&limit=${pageSize}`
    if (searchQuery.value) {
      url += `&q=${encodeURIComponent(searchQuery.value)}`
    }
    const resp = await fetch(url)
    const data = await resp.json()
    if (data.success) {
      logContent.value = data.content || ''
      totalLines.value = data.total_lines || 0
    }
  } catch (_) {  }
  loading.value = false
}

function doSearch() {
  offset.value = 0
  loadFileContent()
}

function nextPage() {
  offset.value += pageSize
  loadFileContent()
}

function prevPage() {
  offset.value = Math.max(0, offset.value - pageSize)
  loadFileContent()
}

function logLevelClass(line) {
  if (line.includes(' ERROR ') || line.includes(' err ')) return 'text-red-600'
  if (line.includes(' WARN ') || line.includes(' warn ')) return 'text-amber-600'
  return 'text-slate-700'
}

function highlightMatch(text) {
  if (!searchQuery.value) return text
  const escaped = searchQuery.value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return text.replace(new RegExp(`(${escaped})`, 'gi'), '<mark class="bg-yellow-200">$1</mark>')
}
</script>

<template>
  <div class="flex-1 flex flex-col min-w-0 min-h-0">
    <div v-if="props.file" class="border-b border-slate-200 px-3 py-1.5 flex items-center gap-2 shrink-0">
      <span class="text-xs text-slate-500 font-medium truncate">{{ props.service }}/{{ props.file }}</span>
      <input
        v-model="searchQuery"
        type="text"
        placeholder="Search..."
        class="flex-1 text-xs border rounded px-2 py-1 max-w-xs"
        @keyup.enter="doSearch"
      />
      <button
        class="text-xs px-2 py-1 bg-blue-500 text-white rounded hover:bg-blue-600"
        @click="doSearch"
      >Search</button>
    </div>

    <div class="flex-1 overflow-auto font-mono text-[11px] leading-4 light-scroll">
      <div v-if="loading" class="p-4 text-xs text-slate-400">Loading...</div>
      <div v-else-if="!props.file" class="p-4 text-xs text-slate-400">Select a log file to view</div>
      <div v-else-if="logLines.length === 0" class="p-4 text-xs text-slate-400">No content</div>
      <table v-else class="w-full">
        <tr v-for="(line, idx) in logLines" :key="idx" class="hover:bg-yellow-50">
          <td class="text-right text-slate-300 select-none px-2 border-r border-slate-100 align-top whitespace-nowrap">{{ line.num }}</td>
          <td class="px-2 whitespace-pre-wrap break-all" :class="logLevelClass(line.text)">
            <template v-if="searchQuery">
              <span v-html="highlightMatch(line.text)"></span>
            </template>
            <template v-else>{{ line.text }}</template>
          </td>
        </tr>
      </table>
    </div>

    <div v-if="props.file && totalLines > 0" class="border-t border-slate-200 px-3 py-1 flex items-center justify-between text-xs text-slate-500 shrink-0">
      <span>{{ totalLines }} lines total</span>
      <div class="flex gap-2">
        <button v-if="offset > 0" @click="prevPage" class="px-2 py-0.5 border rounded hover:bg-slate-50">Previous</button>
        <button v-if="offset + pageSize < totalLines" @click="nextPage" class="px-2 py-0.5 border rounded hover:bg-slate-50">Next</button>
      </div>
    </div>
  </div>
</template>
