<script setup>
import { ref, computed } from 'vue'
import { Box, ArrowLeft } from 'lucide-vue-next'
import AppBackupsPanel from './AppBackupsPanel.vue'

const props = defineProps({
  appName: { type: String, required: true },
  appInfo: { type: Object, default: null },
  services: { type: Array, default: () => [] },
})

const emit = defineEmits(['close', 'open-service'])

const activeTab = ref('overview')

const tabs = [
  { key: 'overview', label: 'Overview' },
  { key: 'backups', label: 'Backups' },
]

const appServices = computed(() => props.appInfo?.services || [])
function liveStatus(svcName) {
  return props.services.find(s => s.name === svcName) || null
}
</script>

<template>
  <div class="flex-1 flex flex-col bg-white min-w-0 overflow-hidden">
    <div class="bg-white border-b border-slate-200 px-4 py-2 flex items-center">
      <button
        class="p-1 text-slate-500 hover:bg-slate-100 rounded mr-2"
        @click="emit('close')"
        title="Back"
      >
        <ArrowLeft :size="14" />
      </button>
      <Box :size="16" class="text-slate-500 mr-2" />
      <span class="text-sm font-semibold text-slate-800">{{ appName }}</span>
      <span v-if="appInfo?.description" class="text-xs text-slate-400 ml-2">{{ appInfo.description }}</span>
    </div>

    <div class="border-b border-slate-200 bg-slate-50 flex">
      <button
        v-for="tab in tabs"
        :key="tab.key"
        class="px-4 py-2 text-xs font-medium border-b-2 transition"
        :class="activeTab === tab.key
          ? 'border-blue-600 text-blue-600'
          : 'border-transparent text-slate-500 hover:text-slate-700'"
        @click="activeTab = tab.key"
      >
        {{ tab.label }}
      </button>
    </div>

    <template v-if="activeTab === 'overview'">
      <div class="flex-1 overflow-y-auto p-4">
        <div class="text-xs font-medium text-slate-600 mb-2">Services</div>
        <div v-if="appServices.length === 0" class="text-xs text-slate-400">No services in this app.</div>
        <div v-else class="space-y-1">
          <div
            v-for="svc in appServices"
            :key="svc.name"
            class="p-2 border border-slate-200 rounded hover:bg-slate-50 cursor-pointer flex items-center"
            @click="emit('open-service', svc.name)"
          >
            <div class="flex-1 min-w-0">
              <div class="text-xs font-medium text-slate-700">{{ svc.name }}</div>
              <div v-if="svc.description" class="text-[10px] text-slate-400">{{ svc.description }}</div>
            </div>
            <div class="text-[10px] text-slate-400">
              <span v-if="liveStatus(svc.name)?.status === 'running'" class="text-green-600">● running</span>
              <span v-else-if="liveStatus(svc.name)?.status" class="text-slate-400">○ {{ liveStatus(svc.name).status }}</span>
              <span v-else class="text-slate-300">○ unknown</span>
            </div>
          </div>
        </div>
      </div>
    </template>

    <template v-else-if="activeTab === 'backups'">
      <AppBackupsPanel :app-name="appName" />
    </template>
  </div>
</template>
