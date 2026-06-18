<script setup>
import { ref, computed } from 'vue'
import DataTable from './DataTable.vue'

const props = defineProps({
  results: Object,
})

const activeTab = ref('results')

const data = computed(() => props.results?.data)
const error = computed(() => props.results?.error)
const hasData = computed(() => Array.isArray(data.value) && data.value.length > 0)

const jsonText = computed(() => {
  if (activeTab.value !== 'json') return ''
  if (!props.results) return 'Run a query to see raw JSON here.'
  if (error.value) return JSON.stringify(props.results.raw || { error: error.value }, null, 2)
  return JSON.stringify(data.value || [], null, 2)
})
</script>

<template>
  <div class="h-[70%] flex flex-col overflow-hidden bg-slate-50">
    <div class="flex border-b border-slate-200 bg-white">
      <button
        v-for="tab in ['results', 'json']"
        :key="tab"
        class="px-4 py-2 font-medium text-sm border-b-2 transition capitalize"
        :class="activeTab === tab
          ? 'border-blue-600 text-blue-600'
          : 'border-transparent text-slate-600 hover:bg-slate-50'"
        @click="activeTab = tab"
      >
        {{ tab === 'json' ? 'JSON' : 'Results' }}
      </button>
    </div>

    <div v-show="activeTab === 'results'" class="flex-1 flex min-h-0 min-w-0 results-table">
      <div v-if="error" class="p-4">
        <span class="text-red-500 text-sm font-medium">{{ error }}</span>
      </div>
      <DataTable v-else-if="hasData" :data="data" />
      <p v-else class="text-slate-400 text-xs p-2">
        {{ results ? 'No results.' : 'Run a query to see results here.' }}
      </p>
    </div>

    <div v-show="activeTab === 'json'" class="flex-1 overflow-auto min-h-0 p-2">
      <pre class="bg-slate-50 text-slate-700 rounded border border-slate-200 p-2 font-mono text-xs whitespace-pre-wrap">{{ jsonText }}</pre>
    </div>
  </div>
</template>
